import XCTest

@testable import unwired_mail

// swiftlint:disable file_length function_body_length type_body_length

final class GmailMessageBodyServiceTests: XCTestCase {
  private static let validPNGData = Data(
    base64Encoded:
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAHnOcQAAAAABJRU5ErkJggg=="
  )!

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

  private func pngImageData(marker: UInt8? = nil) -> Data {
    var data = Self.validPNGData
    if let marker {
      data.append(marker)
    }
    return data
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

    let dateWindowPlan = GmailMessageBodyPrefetchPlan(
      messages: [
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
      ],
      pinnedMessageIds: [],
      referenceDate: referenceDate
    )
    XCTAssertEqual(dateWindowPlan.recentMessages.map(\.providerMessageId), ["boundary"])
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

  func testPrefetchPlanTreatsMissingLabelsAsInbox() {
    let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
    let plan = GmailMessageBodyPrefetchPlan(
      messages: [
        prefetchMessage(
          id: "missing-labels",
          internalDateMilliseconds: Int64(referenceDate.timeIntervalSince1970 * 1_000),
          labels: nil
        )
      ],
      pinnedMessageIds: [],
      referenceDate: referenceDate
    )

    XCTAssertEqual(plan.recentMessages.map(\.providerMessageId), ["missing-labels"])
  }

  func testReadFetchesBodyOnDemandAndCachesOnlyEncryptedPayload() async throws {
    let fixture = try makeFixture()

    let body = try await fixture.service.loadMessageBody(message: message, session: session)

    XCTAssertEqual(body.text, "Private trip details")
    XCTAssertNil(body.html)
    XCTAssertEqual(
      fixture.requestPaths, ["/token", "/tokeninfo", "/gmail/v1/users/me/messages/message-001"]
    )
    XCTAssertNotNil(fixture.cache.payload)
    XCTAssertFalse(fixture.cache.serializedPayload.contains("Private trip details"))

    let cachedBody = try await fixture.service.loadMessageBody(message: message, session: session)

    XCTAssertEqual(cachedBody, body)
    XCTAssertEqual(
      fixture.requestPaths, ["/token", "/tokeninfo", "/gmail/v1/users/me/messages/message-001"]
    )
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
      fixture.requestPaths,
      [
        "/token", "/tokeninfo", "/gmail/v1/users/me/messages/message-001",
        "/gmail/v1/users/me/messages/message-001",
      ]
    )
    XCTAssertEqual(fixture.cache.retention, .prefetched)
    XCTAssertEqual(fixture.cache.allowsProtectedEviction, true)
    XCTAssertNotNil(fixture.cache.payload)
    XCTAssertFalse(fixture.cache.serializedPayload.contains("Private trip details"))
    XCTAssertEqual(
      try fixture.service.loadCachedMessageBody(message: prefetchedMessage, session: session)?.text,
      "Private trip details"
    )
  }

  func testPrefetchFetchesSinglePartHTMLAfterBodyFreeMetadataCheck() async throws {
    let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
    let prefetchedMessage = prefetchMessage(
      id: "message-001",
      internalDateMilliseconds: Int64(referenceDate.timeIntervalSince1970 * 1_000),
      labels: ["INBOX"]
    )
    let fixture = try makeFixture(
      metadataStore: RecordingBodyPrefetchMetadataStore(messages: [prefetchedMessage]),
      prefetchMetadataResponse: """
        {
          "id": "message-001",
          "payload": {
            "mimeType": "text/html",
            "headers": [{"name": "Content-Type", "value": "text/html; charset=UTF-8"}]
          }
        }
        """,
      messageResponse:
        #"{"id":"message-001","payload":{"mimeType":"text/html","body":{"data":"PHA+UmVjZWlwdDwvcD4="}}}"#
    )

    try await fixture.service.prefetchMessageBodies(
      connection: connection,
      pinnedMessageIds: [],
      referenceDate: referenceDate,
      session: session
    )

    XCTAssertEqual(
      try fixture.service.loadCachedMessageBody(message: prefetchedMessage, session: session)?.html,
      "<p>Receipt</p>"
    )
    XCTAssertEqual(
      fixture.requestQueries.compactMap { $0 as? String },
      [
        "format=metadata&metadataHeaders=Content-Type&metadataHeaders=Content-Disposition",
        "format=full",
      ]
    )
  }

  func testPrefetchAcceptsHeaderlessTopLevelTextBody() async throws {
    let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
    let prefetchedMessage = prefetchMessage(
      id: "message-001",
      internalDateMilliseconds: Int64(referenceDate.timeIntervalSince1970 * 1_000),
      labels: ["INBOX"]
    )
    let fixture = try makeFixture(
      metadataStore: RecordingBodyPrefetchMetadataStore(messages: [prefetchedMessage]),
      prefetchMetadataResponse:
        #"{"id":"message-001","payload":{"mimeType":"text/plain","headers":[]}}"#
    )

    try await fixture.service.prefetchMessageBodies(
      connection: connection,
      pinnedMessageIds: [],
      referenceDate: referenceDate,
      session: session
    )

    XCTAssertEqual(
      try fixture.service.loadCachedMessageBody(message: prefetchedMessage, session: session)?.text,
      "Private trip details"
    )
  }

  func testPrefetchRecordsTopLevelAttachmentExclusionWithoutRetrying() async throws {
    let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
    let prefetchedMessage = prefetchMessage(
      id: "message-001",
      internalDateMilliseconds: Int64(referenceDate.timeIntervalSince1970 * 1_000),
      labels: ["INBOX"]
    )
    let fixture = try makeFixture(
      metadataStore: RecordingBodyPrefetchMetadataStore(messages: [prefetchedMessage]),
      prefetchMetadataResponse: """
        {
          "id": "message-001",
          "payload": {
            "mimeType": "text/plain",
            "headers": [
              {"name": "Content-Type", "value": "text/plain; charset=UTF-8"},
              {"name": "Content-Disposition", "value": "attachment"}
            ]
          }
        }
        """
    )

    try await fixture.service.prefetchMessageBodies(
      connection: connection,
      pinnedMessageIds: [],
      referenceDate: referenceDate,
      session: session
    )
    try await fixture.service.prefetchMessageBodies(
      connection: connection,
      pinnedMessageIds: [],
      referenceDate: referenceDate,
      session: session
    )

    XCTAssertEqual(
      fixture.requestQueries.compactMap { $0 as? String },
      ["format=metadata&metadataHeaders=Content-Type&metadataHeaders=Content-Disposition"]
    )
    XCTAssertNotNil(fixture.cache.payload)
    XCTAssertEqual(fixture.cache.allowsProtectedEviction, false)
    XCTAssertNil(
      try fixture.service.loadCachedMessageBody(message: prefetchedMessage, session: session)
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

  func testPrefetchStopsAfterGmailRequestFailure() async throws {
    let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
    let firstPrefetchedMessage = prefetchMessage(
      id: "message-001",
      internalDateMilliseconds: Int64(referenceDate.timeIntervalSince1970 * 1_000),
      labels: ["INBOX"]
    )
    let secondPrefetchedMessage = prefetchMessage(
      id: "message-002",
      internalDateMilliseconds: Int64(referenceDate.timeIntervalSince1970 * 1_000) - 1,
      labels: ["INBOX"]
    )
    let fixture = try makeFixture(
      metadataStore: RecordingBodyPrefetchMetadataStore(
        messages: [firstPrefetchedMessage, secondPrefetchedMessage]
      ),
      messageStatusCode: 503
    )

    do {
      try await fixture.service.prefetchMessageBodies(
        connection: connection,
        pinnedMessageIds: [],
        referenceDate: referenceDate,
        session: session
      )
      XCTFail("Expected Gmail request failure")
    } catch GmailMessageBodyError.gmailRequestFailed {
      XCTAssertEqual(
        fixture.requestPaths, ["/token", "/tokeninfo", "/gmail/v1/users/me/messages/message-001"])
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
      4
    )
  }

  func testCachedReadDoesNotFetchMissingBodyFromGmail() throws {
    let fixture = try makeFixture()

    let body = try fixture.service.loadCachedMessageBody(message: message, session: session)

    XCTAssertNil(body)
    XCTAssertEqual(fixture.requestPaths, [])
  }

  func testCachedPayloadDetectsEntityEncodedCIDReference() throws {
    let encoded = try GmailMessageBodyCachePayload.encode(
      GmailMessageBody(
        text: "Receipt",
        html: #"<p>Receipt</p><img src="c&#105;d:logo@example.com">"#
      )
    )

    guard case .body(let body) = try GmailMessageBodyCachePayload.decode(encoded) else {
      return XCTFail("Expected cached body")
    }

    XCTAssertFalse(body.didResolveInlineImages)
  }

  func testCachedPayloadPropagatesCancellationDuringCIDInspection() throws {
    let encoded = try GmailMessageBodyCachePayload.encode(
      GmailMessageBody(
        text: "Receipt",
        html: #"<p>Receipt</p><img src="cid:logo@example.com">"#
      )
    )

    XCTAssertThrowsError(
      try GmailMessageBodyCachePayload.decode(encoded) {
        throw CancellationError()
      }
    ) { error in
      XCTAssertTrue(error is CancellationError)
    }
  }

  func testCachedPayloadSkipsCIDParsingForOrdinaryHTML() throws {
    XCTAssertFalse(
      MessageHTMLSanitizer.mayReferenceInlineImage(
        in: #"<p>Receipt &amp; delivery details</p><img src="https://example.com/logo.png">"#
      )
    )
    XCTAssertTrue(
      MessageHTMLSanitizer.mayReferenceInlineImage(
        in: #"<p>Receipt</p><img src="c&#105;d&#58;logo@example.com">"#
      )
    )
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
    XCTAssertEqual(body.html, "<table><tr><td>Hi</td><td>There</td></tr></table>")
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
    XCTAssertEqual(body.html, "<p>Actual content</p>")
  }

  func testReadFallsBackToHTMLWhenPlainTextAlternativeIsEmpty() async throws {
    let fixture = try makeFixture(
      messageResponse:
        #"{"id":"message-001","payload":{"mimeType":"multipart/alternative","parts":["#
        + #"{"mimeType":"text/plain","body":{"data":""}},"#
        + #"{"mimeType":"text/html","body":{"data":"PHA+QWN0dWFsIGNvbnRlbnQ8L3A+"}}]}}"#
    )

    let body = try await fixture.service.loadMessageBody(message: message, session: session)

    XCTAssertTrue(body.text.contains("Actual content"))
    XCTAssertEqual(body.html, "<p>Actual content</p>")
  }

  func testReadKeepsHTMLPairedWithPlainTextFromSameAlternative() async throws {
    let fixture = try makeFixture(
      messageResponse:
        #"{"id":"message-001","payload":{"mimeType":"multipart/mixed","parts":["#
        + #"{"mimeType":"text/plain","body":{"data":"Q292ZXIgbm90ZQ=="}},"#
        + #"{"parts":[{"mimeType":"multipart/alternative","parts":["#
        + #"{"mimeType":"text/plain","body":{"data":"TmVzdGVkIGNvbnRlbnQ="}},"#
        + #"{"mimeType":"text/html","body":{"data":"PHA+TmVzdGVkIGNvbnRlbnQ8L3A+"}}]}]}]}}"#
    )

    let body = try await fixture.service.loadMessageBody(message: message, session: session)

    XCTAssertEqual(body.text, "Nested content")
    XCTAssertEqual(body.html, "<p>Nested content</p>")
  }

  func testReadSkipsUnusableAlternativeBeforeValidAlternative() async throws {
    let fixture = try makeFixture(
      messageResponse:
        #"{"id":"message-001","payload":{"mimeType":"multipart/mixed","parts":["#
        + #"{"mimeType":"multipart/alternative","parts":["#
        + #"{"mimeType":"text/plain","body":{"data":""}},"#
        + #"{"mimeType":"text/html","body":{"data":"%%%"}}]},"#
        + #"{"mimeType":"multipart/alternative","parts":["#
        + #"{"mimeType":"text/plain","body":{"data":"VmFsaWQgY29udGVudA=="}},"#
        + #"{"mimeType":"text/html","body":{"data":"PHA+VmFsaWQgY29udGVudDwvcD4="}}]}]}}"#
    )

    let body = try await fixture.service.loadMessageBody(message: message, session: session)

    XCTAssertEqual(body.text, "Valid content")
    XCTAssertEqual(body.html, "<p>Valid content</p>")
  }

  func testReadTriesLaterAlternativeAfterAttachmentBackedAlternativeFails() async throws {
    let fixture = try makeFixture(
      attachmentStatusCode: 503,
      messageResponse:
        #"{"id":"message-001","payload":{"mimeType":"multipart/mixed","parts":["#
        + #"{"mimeType":"multipart/alternative","parts":["#
        + #"{"mimeType":"text/html","body":{"attachmentId":"html-001"}}]},"#
        + #"{"mimeType":"multipart/alternative","parts":["#
        + #"{"mimeType":"text/plain","body":{"data":"VmFsaWQgY29udGVudA=="}}]}]}}"#
    )

    let body = try await fixture.service.loadMessageBody(message: message, session: session)

    XCTAssertEqual(body, GmailMessageBody(text: "Valid content"))
    XCTAssertEqual(
      fixture.requestPaths.compactMap { $0 as? String }
        .filter { $0.hasSuffix("/attachments/html-001") }.count,
      1
    )
  }

  func testReadKeepsPlainTextWhenHTMLAlternativeIsMalformed() async throws {
    let fixture = try makeFixture(
      messageResponse:
        #"{"id":"message-001","payload":{"mimeType":"multipart/alternative","parts":["#
        + #"{"mimeType":"text/plain","body":{"data":"UGxhaW4gY29udGVudA=="}},"#
        + #"{"mimeType":"text/html","body":{"data":"%%%"}}]}}"#
    )

    let body = try await fixture.service.loadMessageBody(message: message, session: session)

    XCTAssertEqual(body.text, "Plain content")
    XCTAssertNil(body.html)
  }

  func testReadRetriesAttachmentBackedHTMLAfterTransientFailure() async throws {
    let fixture = try makeFixture(
      attachmentStatusCode: 503,
      messageResponse:
        #"{"id":"message-001","payload":{"mimeType":"multipart/alternative","parts":["#
        + #"{"mimeType":"text/plain","body":{"data":"UGxhaW4gY29udGVudA=="}},"#
        + #"{"mimeType":"text/html","body":{"attachmentId":"html-001"}}]}}"#
    )

    let firstBody = try await fixture.service.loadMessageBody(message: message, session: session)
    let secondBody = try await fixture.service.loadMessageBody(message: message, session: session)

    XCTAssertEqual(firstBody, GmailMessageBody(text: "Plain content"))
    XCTAssertEqual(secondBody, firstBody)
    XCTAssertNil(fixture.cache.payload)
    XCTAssertEqual(
      fixture.requestPaths.compactMap { $0 as? String }
        .filter { $0.hasSuffix("/attachments/html-001") }.count,
      2
    )
  }

  func testReadRetriesAttachmentBackedPlainTextAfterTransientFailure() async throws {
    let fixture = try makeFixture(
      attachmentIdWithStatus: "plain-001",
      attachmentStatusCode: 503,
      messageResponse:
        #"{"id":"message-001","payload":{"mimeType":"multipart/alternative","parts":["#
        + #"{"mimeType":"text/plain","body":{"attachmentId":"plain-001"}},"#
        + #"{"mimeType":"text/html","body":{"data":"PHA+SFRNTCBjb250ZW50PC9wPg=="}}]}}"#
    )

    let firstBody = try await fixture.service.loadMessageBody(message: message, session: session)
    let secondBody = try await fixture.service.loadMessageBody(message: message, session: session)

    XCTAssertTrue(firstBody.text.contains("HTML content"))
    XCTAssertEqual(firstBody.html, "<p>HTML content</p>")
    XCTAssertEqual(secondBody, firstBody)
    XCTAssertNil(fixture.cache.payload)
    XCTAssertEqual(
      fixture.requestPaths.compactMap { $0 as? String }
        .filter { $0.hasSuffix("/attachments/plain-001") }.count,
      2
    )
  }

  func testReadRetainsPlainTextAndHTMLAlternatives() async throws {
    let fixture = try makeFixture(
      messageResponse:
        #"{"id":"message-001","payload":{"mimeType":"multipart/alternative","parts":["#
        + #"{"mimeType":"text/plain","body":{"data":"UGxhaW4gY29udGVudA=="}},"#
        + #"{"mimeType":"text/html","body":{"data":"PHA+SFRNTCBjb250ZW50PC9wPg=="}}]}}"#
    )

    let body = try await fixture.service.loadMessageBody(message: message, session: session)

    XCTAssertEqual(body.text, "Plain content")
    XCTAssertEqual(body.html, "<p>HTML content</p>")

    let cachedBody = try fixture.service.loadCachedMessageBody(message: message, session: session)
    XCTAssertEqual(cachedBody, body)
    XCTAssertFalse(fixture.cache.serializedPayload.contains("Plain content"))
    XCTAssertFalse(fixture.cache.serializedPayload.contains("HTML content"))
  }

  func testReadFetchesOnlySanitizedReferencedValidInlineImagesWithoutCachingThem() async throws {
    let imageData = pngImageData()
    let html = """
      <p>Receipt</p>
      <img src="cid:image-001@example.com">
      <img src="cid:unsupported@example.com">
      <img src="cid:oversized@example.com">
      <img src="cid:malformed@example.com">
      <img src="cid:missing@example.com">
      <div style="display: none"><img src="cid:hidden@example.com"></div>
      <img hidden src="cid:hidden-attribute@example.com">
      """
    let fixture = try makeFixture(
      attachmentResponses: [
        "inline-png": #"{"data":"\#(imageData.base64EncodedString())"}"#,
        "hidden": #"{"data":"\#(imageData.base64EncodedString())"}"#,
        "hidden-attribute": #"{"data":"\#(imageData.base64EncodedString())"}"#,
        "unreferenced": #"{"data":"\#(imageData.base64EncodedString())"}"#,
      ],
      messageResponse: """
        {
          "id": "message-001",
          "payload": {
            "mimeType": "multipart/related",
            "parts": [
              {
                "mimeType": "text/html",
                "body": {"data": "\(Data(html.utf8).base64EncodedString())"}
              },
              {
                "mimeType": "image/png",
                "filename": "attachment.png",
                "headers": [
                  {"name": "Content-ID", "value": " <Image-001@Example.COM> "},
                  {"name": "Content-Disposition", "value": "inline; filename=attachment.png"}
                ],
                "body": {"attachmentId": "inline-png", "size": \(imageData.count)}
              },
              {
                "mimeType": "image/svg+xml",
                "headers": [{"name": "Content-ID", "value": "<unsupported@example.com>"}],
                "body": {"attachmentId": "unsupported", "size": 100}
              },
              {
                "mimeType": "image/png",
                "headers": [{"name": "Content-ID", "value": "<oversized@example.com>"}],
                "body": {"attachmentId": "oversized", "size": 5242881}
              },
              {
                "mimeType": "image/png",
                "headers": [{"name": "Content-ID", "value": "<malformed@example.com>"}],
                "body": {"data": "bm90LWEtcG5n", "size": 9}
              },
              {
                "mimeType": "image/png",
                "headers": [{"name": "Content-ID", "value": "<unreferenced@example.com>"}],
                "body": {"attachmentId": "unreferenced", "size": \(imageData.count)}
              },
              {
                "mimeType": "image/png",
                "headers": [{"name": "Content-ID", "value": "<hidden@example.com>"}],
                "body": {"attachmentId": "hidden", "size": \(imageData.count)}
              },
              {
                "mimeType": "image/png",
                "headers": [{"name": "Content-ID", "value": "<hidden-attribute@example.com>"}],
                "body": {"attachmentId": "hidden-attribute", "size": \(imageData.count)}
              }
            ]
          }
        }
        """
    )

    let body = try await fixture.service.loadMessageBody(message: message, session: session)

    XCTAssertEqual(
      body.inlineImages,
      [
        MailboxMessageInlineImage(
          contentID: "image-001@example.com",
          data: imageData,
          mimeType: "image/png"
        )
      ]
    )
    XCTAssertEqual(
      fixture.requestPaths.compactMap { $0 as? String }.filter {
        $0.contains("/attachments/")
      },
      ["/gmail/v1/users/me/messages/message-001/attachments/inline-png"]
    )
    let cachedBody = try fixture.service.loadCachedMessageBody(message: message, session: session)
    XCTAssertEqual(cachedBody?.text, body.text)
    XCTAssertEqual(cachedBody?.html, body.html)
    XCTAssertEqual(cachedBody?.inlineImages, [])
    XCTAssertEqual(cachedBody?.didResolveInlineImages, false)
  }

  func testReadResolvesImageOnlyHTMLBody() async throws {
    let imageData = pngImageData()
    let html = #"<img src="cid:barcode@example.com" alt="Barcode">"#
    let fixture = try makeFixture(
      attachmentResponses: [
        "barcode": #"{"data":"\#(imageData.base64EncodedString())"}"#
      ],
      messageResponse: """
        {
          "id": "message-001",
          "payload": {
            "mimeType": "multipart/related",
            "parts": [
              {
                "mimeType": "text/html",
                "body": {"data": "\(Data(html.utf8).base64EncodedString())"}
              },
              {
                "mimeType": "image/png",
                "headers": [{"name": "Content-ID", "value": "<barcode@example.com>"}],
                "body": {"attachmentId": "barcode", "size": \(imageData.count)}
              }
            ]
          }
        }
        """
    )

    let body = try await fixture.service.loadMessageBody(message: message, session: session)

    XCTAssertEqual(body.html, html)
    XCTAssertEqual(body.inlineImages.map(\.contentID), ["barcode@example.com"])
    XCTAssertEqual(
      fixture.requestPaths.compactMap { $0 as? String }.filter {
        $0.contains("/attachments/")
      },
      ["/gmail/v1/users/me/messages/message-001/attachments/barcode"]
    )
  }

  func testReadDoesNotResolveCIDImageInsideAttachmentTree() async throws {
    let imageData = pngImageData()
    let html = #"<p>Receipt</p><img src="cid:attached@example.com">"#
    let fixture = try makeFixture(
      attachmentResponses: [
        "attached-image": #"{"data":"\#(imageData.base64EncodedString())"}"#
      ],
      messageResponse: """
        {
          "id": "message-001",
          "payload": {
            "mimeType": "multipart/mixed",
            "parts": [
              {
                "mimeType": "text/html",
                "body": {"data": "\(Data(html.utf8).base64EncodedString())"}
              },
              {
                "mimeType": "message/rfc822",
                "filename": "forwarded-message.eml",
                "parts": [
                  {
                    "mimeType": "image/png",
                    "headers": [{"name": "Content-ID", "value": "<attached@example.com>"}],
                    "body": {"attachmentId": "attached-image", "size": \(imageData.count)}
                  }
                ]
              }
            ]
          }
        }
        """
    )

    let body = try await fixture.service.loadMessageBody(message: message, session: session)

    XCTAssertEqual(body.inlineImages, [])
    XCTAssertFalse(
      fixture.requestPaths.compactMap { $0 as? String }.contains {
        $0.contains("/attachments/")
      }
    )
  }

  func testReadDoesNotResolveFilenameOnlyCIDLeafFromMixedFallback() async throws {
    let imageData = pngImageData()
    let html = #"<p>Receipt</p><img src="cid:attached@example.com">"#
    let fixture = try makeFixture(
      attachmentResponses: [
        "attached-image": #"{"data":"\#(imageData.base64EncodedString())"}"#
      ],
      messageResponse: """
        {
          "id": "message-001",
          "payload": {
            "mimeType": "multipart/mixed",
            "parts": [
              {
                "mimeType": "text/html",
                "body": {"data": "\(Data(html.utf8).base64EncodedString())"}
              },
              {
                "mimeType": "image/png",
                "filename": "attached.png",
                "headers": [{"name": "Content-ID", "value": "<attached@example.com>"}],
                "body": {"attachmentId": "attached-image", "size": \(imageData.count)}
              }
            ]
          }
        }
        """
    )

    let body = try await fixture.service.loadMessageBody(message: message, session: session)

    XCTAssertEqual(body.inlineImages, [])
    XCTAssertFalse(
      fixture.requestPaths.compactMap { $0 as? String }.contains {
        $0.contains("/attachments/")
      }
    )
  }

  func testReadDoesNotResolveCIDImageInsideBareEmbeddedMessage() async throws {
    let imageData = pngImageData()
    let html = #"<p>Receipt</p><img src="cid:attached@example.com">"#
    let fixture = try makeFixture(
      attachmentResponses: [
        "attached-image": #"{"data":"\#(imageData.base64EncodedString())"}"#
      ],
      messageResponse: """
        {
          "id": "message-001",
          "payload": {
            "mimeType": "multipart/mixed",
            "parts": [
              {
                "mimeType": "text/html",
                "body": {"data": "\(Data(html.utf8).base64EncodedString())"}
              },
              {
                "mimeType": "message/rfc822",
                "parts": [
                  {
                    "mimeType": "image/png",
                    "headers": [{"name": "Content-ID", "value": "<attached@example.com>"}],
                    "body": {"attachmentId": "attached-image", "size": \(imageData.count)}
                  }
                ]
              }
            ]
          }
        }
        """
    )

    let body = try await fixture.service.loadMessageBody(message: message, session: session)

    XCTAssertEqual(body.inlineImages, [])
    XCTAssertFalse(
      fixture.requestPaths.compactMap { $0 as? String }.contains {
        $0.contains("/attachments/")
      }
    )
  }

  func testReadRejectsInlineImageWithExcessiveDecodedDimensions() async throws {
    let imageData = Data(
      base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAJxAAACcQCAYAAAC6TmInAAAAC0lEQVR4nGNgAAIAAAUAAXpeqz8AAAAASUVORK5CYII="
    )!
    let html = #"<p>Receipt</p><img src="cid:oversized@example.com">"#
    let fixture = try makeFixture(
      messageResponse: """
        {
          "id": "message-001",
          "payload": {
            "mimeType": "multipart/related",
            "parts": [
              {
                "mimeType": "text/html",
                "body": {"data": "\(Data(html.utf8).base64EncodedString())"}
              },
              {
                "mimeType": "image/png",
                "headers": [{"name": "Content-ID", "value": "<oversized@example.com>"}],
                "body": {"data": "\(imageData.base64EncodedString())", "size": \(imageData.count)}
              }
            ]
          }
        }
        """
    )

    let body = try await fixture.service.loadMessageBody(message: message, session: session)

    XCTAssertEqual(body.inlineImages, [])
  }

  func testReadRejectsAnimatedInlineImage() async throws {
    let imageData = Data([
      0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x80, 0x00, 0x00, 0x00,
      0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x21, 0xF9, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x2C,
      0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x02, 0x02, 0x44, 0x01, 0x00,
      0x21, 0xF9, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x2C, 0x00, 0x00, 0x00, 0x00, 0x01,
      0x00, 0x01, 0x00, 0x00, 0x02, 0x02, 0x4C, 0x01, 0x00, 0x3B,
    ])
    let html = #"<p>Receipt</p><img src="cid:animated@example.com">"#
    let fixture = try makeFixture(
      messageResponse: """
        {
          "id": "message-001",
          "payload": {
            "mimeType": "multipart/related",
            "parts": [
              {
                "mimeType": "text/html",
                "body": {"data": "\(Data(html.utf8).base64EncodedString())"}
              },
              {
                "mimeType": "image/gif",
                "headers": [{"name": "Content-ID", "value": "<animated@example.com>"}],
                "body": {"data": "\(imageData.base64EncodedString())", "size": \(imageData.count)}
              }
            ]
          }
        }
        """
    )

    let body = try await fixture.service.loadMessageBody(message: message, session: session)

    XCTAssertEqual(body.inlineImages, [])
  }

  func testReadCountsAdmittedInlineImagesInsteadOfMissingReferences() async throws {
    let imageData = pngImageData()
    let missingImages = (0..<20).map {
      #"<img src="cid:missing-\#($0)@example.com">"#
    }.joined()
    let html = missingImages + #"<img src="cid:valid@example.com">"#
    let fixture = try makeFixture(
      messageResponse: """
        {
          "id": "message-001",
          "payload": {
            "mimeType": "multipart/related",
            "parts": [
              {
                "mimeType": "text/html",
                "body": {"data": "\(Data(html.utf8).base64EncodedString())"}
              },
              {
                "mimeType": "image/png",
                "headers": [{"name": "Content-ID", "value": "<valid@example.com>"}],
                "body": {"data": "\(imageData.base64EncodedString())", "size": \(imageData.count)}
              }
            ]
          }
        }
        """
    )

    let body = try await fixture.service.loadMessageBody(message: message, session: session)

    XCTAssertEqual(body.inlineImages.map(\.contentID), ["valid@example.com"])
  }

  func testReadExcludesCSSZeroSizedImagesBeforeApplyingRequestLimit() async throws {
    let imageData = pngImageData()
    let hiddenImages = (0..<20).map {
      #"<img style="max-width: 0" src="cid:hidden-\#($0)@example.com">"#
    }.joined()
    let html = hiddenImages + #"<img src="cid:visible@example.com">"#
    let hiddenParts = (0..<20).map {
      """
      {
        "mimeType": "image/png",
        "headers": [{"name": "Content-ID", "value": "<hidden-\($0)@example.com>"}],
        "body": {"attachmentId": "hidden-\($0)", "size": \(imageData.count)}
      }
      """
    }.joined(separator: ",")
    let fixture = try makeFixture(
      messageResponse: """
        {
          "id": "message-001",
          "payload": {
            "mimeType": "multipart/related",
            "parts": [
              {
                "mimeType": "text/html",
                "body": {"data": "\(Data(html.utf8).base64EncodedString())"}
              },
              \(hiddenParts),
              {
                "mimeType": "image/png",
                "headers": [{"name": "Content-ID", "value": "<visible@example.com>"}],
                "body": {"data": "\(imageData.base64EncodedString())", "size": \(imageData.count)}
              }
            ]
          }
        }
        """
    )

    let body = try await fixture.service.loadMessageBody(message: message, session: session)

    XCTAssertEqual(body.inlineImages.map(\.contentID), ["visible@example.com"])
    XCTAssertFalse(
      fixture.requestPaths.compactMap { $0 as? String }.contains {
        $0.contains("/attachments/hidden-")
      }
    )
  }

  func testReadResolvesDuplicateCIDFromSelectedMIMEAlternative() async throws {
    let firstImageData = pngImageData(marker: 1)
    let selectedImageData = pngImageData(marker: 2)
    let html = #"<p>Selected</p><img src="cid:duplicate@example.com">"#
    let fixture = try makeFixture(
      messageResponse: """
        {
          "id": "message-001",
          "payload": {
            "mimeType": "multipart/mixed",
            "parts": [
              {
                "mimeType": "multipart/alternative",
                "parts": [{
                  "mimeType": "multipart/related",
                  "parts": [
                    {"mimeType": "text/html", "body": {"data": "%%%"}},
                    {
                      "mimeType": "image/png",
                      "headers": [{"name": "Content-ID", "value": "<duplicate@example.com>"}],
                      "body": {
                        "data": "\(firstImageData.base64EncodedString())",
                        "size": \(firstImageData.count)
                      }
                    }
                  ]
                }]
              },
              {
                "mimeType": "multipart/alternative",
                "parts": [{
                  "mimeType": "multipart/related",
                  "parts": [
                    {
                      "mimeType": "text/html",
                      "body": {"data": "\(Data(html.utf8).base64EncodedString())"}
                    },
                    {
                      "mimeType": "image/png",
                      "headers": [{"name": "Content-ID", "value": "<duplicate@example.com>"}],
                      "body": {
                        "data": "\(selectedImageData.base64EncodedString())",
                        "size": \(selectedImageData.count)
                      }
                    }
                  ]
                }]
              }
            ]
          }
        }
        """
    )

    let body = try await fixture.service.loadMessageBody(message: message, session: session)

    XCTAssertEqual(body.inlineImages.map(\.data), [selectedImageData])
  }

  func testReadResolvesDuplicateCIDFromSelectedAlternativeInsideRelatedScope() async throws {
    let plainImageData = pngImageData(marker: 1)
    let htmlImageData = pngImageData(marker: 2)
    let html = #"<p>Selected</p><img src="cid:duplicate@example.com">"#
    let fixture = try makeFixture(
      messageResponse: """
        {
          "id": "message-001",
          "payload": {
            "mimeType": "multipart/related",
            "parts": [{
              "mimeType": "multipart/alternative",
              "parts": [
                {
                  "mimeType": "multipart/related",
                  "parts": [
                    {"mimeType": "text/plain", "body": {"data": "UGxhaW4="}},
                    {
                      "mimeType": "image/png",
                      "headers": [{"name": "Content-ID", "value": "<duplicate@example.com>"}],
                      "body": {
                        "data": "\(plainImageData.base64EncodedString())",
                        "size": \(plainImageData.count)
                      }
                    }
                  ]
                },
                {
                  "mimeType": "multipart/related",
                  "parts": [
                    {
                      "mimeType": "text/html",
                      "body": {"data": "\(Data(html.utf8).base64EncodedString())"}
                    },
                    {
                      "mimeType": "image/png",
                      "headers": [{"name": "Content-ID", "value": "<duplicate@example.com>"}],
                      "body": {
                        "data": "\(htmlImageData.base64EncodedString())",
                        "size": \(htmlImageData.count)
                      }
                    }
                  ]
                }
              ]
            }]
          }
        }
        """
    )

    let body = try await fixture.service.loadMessageBody(message: message, session: session)

    XCTAssertEqual(body.inlineImages.map(\.data), [htmlImageData])
  }

  func testReadResolvesDuplicateCIDFromSelectedNestedAlternative() async throws {
    let plainImageData = pngImageData(marker: 1)
    let htmlImageData = pngImageData(marker: 2)
    let html = #"<p>Selected</p><img src="cid:duplicate@example.com">"#
    let fixture = try makeFixture(
      messageResponse: """
        {
          "id": "message-001",
          "payload": {
            "mimeType": "multipart/alternative",
            "parts": [
              {"mimeType": "text/plain", "body": {"data": "UGxhaW4="}},
              {
                "mimeType": "multipart/alternative",
                "parts": [
                  {
                    "mimeType": "multipart/related",
                    "parts": [
                      {"mimeType": "text/plain", "body": {"data": "TmVzdGVkIHBsYWlu"}},
                      {
                        "mimeType": "image/png",
                        "headers": [{"name": "Content-ID", "value": "<duplicate@example.com>"}],
                        "body": {
                          "data": "\(plainImageData.base64EncodedString())",
                          "size": \(plainImageData.count)
                        }
                      }
                    ]
                  },
                  {
                    "mimeType": "multipart/related",
                    "parts": [
                      {
                        "mimeType": "text/html",
                        "body": {"data": "\(Data(html.utf8).base64EncodedString())"}
                      },
                      {
                        "mimeType": "image/png",
                        "headers": [{"name": "Content-ID", "value": "<duplicate@example.com>"}],
                        "body": {
                          "data": "\(htmlImageData.base64EncodedString())",
                          "size": \(htmlImageData.count)
                        }
                      }
                    ]
                  }
                ]
              }
            ]
          }
        }
        """
    )

    let body = try await fixture.service.loadMessageBody(message: message, session: session)

    XCTAssertEqual(body.inlineImages.map(\.data), [htmlImageData])
  }

  func testReadResolvesCIDFromEnclosingRelatedScope() async throws {
    let imageData = pngImageData()
    let html = #"<p>Receipt</p><img src="cid:related@example.com">"#
    let fixture = try makeFixture(
      messageResponse: """
        {
          "id": "message-001",
          "payload": {
            "mimeType": "multipart/related",
            "parts": [
              {
                "mimeType": "multipart/alternative",
                "parts": [
                  {"mimeType": "text/plain", "body": {"data": "UmVjZWlwdA=="}},
                  {
                    "mimeType": "text/html",
                    "body": {"data": "\(Data(html.utf8).base64EncodedString())"}
                  }
                ]
              },
              {
                "mimeType": "image/png",
                "headers": [{"name": "Content-ID", "value": "<related@example.com>"}],
                "body": {"data": "\(imageData.base64EncodedString())", "size": \(imageData.count)}
              }
            ]
          }
        }
        """
    )

    let body = try await fixture.service.loadMessageBody(message: message, session: session)

    XCTAssertEqual(body.inlineImages.map(\.contentID), ["related@example.com"])
  }

  func testReadResolvesInlineCIDSiblingFromEnclosingMixedScope() async throws {
    let imageData = pngImageData()
    let html = #"<p>Receipt</p><img src="cid:mixed@example.com">"#
    let fixture = try makeFixture(
      messageResponse: """
        {
          "id": "message-001",
          "payload": {
            "mimeType": "multipart/mixed",
            "parts": [
              {
                "mimeType": "multipart/alternative",
                "parts": [
                  {"mimeType": "text/plain", "body": {"data": "UmVjZWlwdA=="}},
                  {
                    "mimeType": "text/html",
                    "body": {"data": "\(Data(html.utf8).base64EncodedString())"}
                  }
                ]
              },
              {
                "mimeType": "image/png",
                "headers": [
                  {"name": "Content-ID", "value": "<mixed@example.com>"},
                  {"name": "Content-Disposition", "value": "inline"}
                ],
                "body": {"data": "\(imageData.base64EncodedString())", "size": \(imageData.count)}
              }
            ]
          }
        }
        """
    )

    let body = try await fixture.service.loadMessageBody(message: message, session: session)

    XCTAssertEqual(body.inlineImages.map(\.contentID), ["mixed@example.com"])
  }

  func testReadResolvesDispositionlessCIDSiblingFromEnclosingMixedScope() async throws {
    let imageData = pngImageData()
    let html = #"<p>Receipt</p><img src="cid:mixed@example.com">"#
    let fixture = try makeFixture(
      messageResponse: """
        {
          "id": "message-001",
          "payload": {
            "mimeType": "multipart/mixed",
            "parts": [
              {
                "mimeType": "multipart/alternative",
                "parts": [
                  {"mimeType": "text/plain", "body": {"data": "UmVjZWlwdA=="}},
                  {
                    "mimeType": "text/html",
                    "body": {"data": "\(Data(html.utf8).base64EncodedString())"}
                  }
                ]
              },
              {
                "mimeType": "image/png",
                "headers": [{"name": "Content-ID", "value": "<mixed@example.com>"}],
                "body": {"data": "\(imageData.base64EncodedString())", "size": \(imageData.count)}
              }
            ]
          }
        }
        """
    )

    let body = try await fixture.service.loadMessageBody(message: message, session: session)

    XCTAssertEqual(body.inlineImages.map(\.contentID), ["mixed@example.com"])
  }

  func testReadPrefersNearestRelatedScopeForDirectHTMLBodyDuplicateCID() async throws {
    let innerImageData = pngImageData(marker: 1)
    let outerImageData = pngImageData(marker: 2)
    let html = #"<p>Receipt</p><img src="cid:duplicate@example.com">"#
    let fixture = try makeFixture(
      messageResponse: """
        {
          "id": "message-001",
          "payload": {
            "mimeType": "multipart/related",
            "parts": [
              {
                "mimeType": "multipart/related",
                "parts": [
                  {
                    "mimeType": "text/html",
                    "body": {"data": "\(Data(html.utf8).base64EncodedString())"}
                  },
                  {
                    "mimeType": "image/png",
                    "headers": [{"name": "Content-ID", "value": "<duplicate@example.com>"}],
                    "body": {
                      "data": "\(innerImageData.base64EncodedString())",
                      "size": \(innerImageData.count)
                    }
                  }
                ]
              },
              {
                "mimeType": "image/png",
                "headers": [{"name": "Content-ID", "value": "<duplicate@example.com>"}],
                "body": {
                  "data": "\(outerImageData.base64EncodedString())",
                  "size": \(outerImageData.count)
                }
              }
            ]
          }
        }
        """
    )

    let body = try await fixture.service.loadMessageBody(message: message, session: session)

    XCTAssertEqual(body.inlineImages.map(\.data), [innerImageData])
  }

  func testReadBoundsFailedInlineImageFetchAttempts() async throws {
    let contentIDs = (0..<21).map { "malformed-\($0)@example.com" }
    let html = contentIDs.map { #"<img src="cid:\#($0)">"# }.joined()
    let imageParts = contentIDs.enumerated().map { index, contentID in
      """
      {
        "mimeType": "image/png",
        "headers": [{"name": "Content-ID", "value": "<\(contentID)>"}],
        "body": {"attachmentId": "image-\(index)", "size": 9}
      }
      """
    }.joined(separator: ",")
    let attachmentResponses = Dictionary(
      uniqueKeysWithValues: (0..<21).map { ("image-\($0)", #"{"data":"bm90LWEtcG5n"}"#) }
    )
    let fixture = try makeFixture(
      attachmentResponses: attachmentResponses,
      messageResponse: """
        {
          "id": "message-001",
          "payload": {
            "mimeType": "multipart/related",
            "parts": [
              {
                "mimeType": "text/html",
                "body": {"data": "\(Data(html.utf8).base64EncodedString())"}
              },
              \(imageParts)
            ]
          }
        }
        """
    )

    let body = try await fixture.service.loadMessageBody(message: message, session: session)

    XCTAssertEqual(body.inlineImages, [])
    XCTAssertEqual(
      fixture.requestPaths.compactMap { $0 as? String }.filter {
        $0.contains("/attachments/")
      }.count,
      20
    )
  }

  func testReadMatchesPercentEscapedCIDToLiteralContentIDHeader() async throws {
    let imageData = pngImageData()
    let html = #"<img src="cid:logo%2541@example.com">"#
    let fixture = try makeFixture(
      messageResponse: """
        {
          "id": "message-001",
          "payload": {
            "mimeType": "multipart/related",
            "parts": [
              {
                "mimeType": "text/html",
                "body": {"data": "\(Data(html.utf8).base64EncodedString())"}
              },
              {
                "mimeType": "image/png",
                "headers": [{"name": "Content-ID", "value": "<logo%41@example.com>"}],
                "body": {"data": "\(imageData.base64EncodedString())", "size": \(imageData.count)}
              }
            ]
          }
        }
        """
    )

    let body = try await fixture.service.loadMessageBody(message: message, session: session)

    XCTAssertEqual(body.inlineImages.map(\.contentID), ["logo%41@example.com"])
  }

  func testPrefetchDoesNotRetrieveInlineImagesButExplicitOpenDoes() async throws {
    let imageData = pngImageData()
    let html = #"<p>Receipt</p><img src="cid:image-001@example.com">"#
    let prefetchedMessage = prefetchMessage(
      id: "message-001",
      internalDateMilliseconds: 1_800_000_000_000,
      labels: ["INBOX"]
    )
    let fixture = try makeFixture(
      attachmentResponses: [
        "inline-png": #"{"data":"\#(imageData.base64EncodedString())"}"#
      ],
      metadataStore: RecordingBodyPrefetchMetadataStore(messages: [prefetchedMessage]),
      prefetchMetadataResponse: """
        {
          "id": "message-001",
          "payload": {
            "mimeType": "multipart/related",
            "headers": [{"name": "Content-Type", "value": "multipart/related; boundary=receipt"}]
          }
        }
        """,
      messageResponse: """
        {
          "id": "message-001",
          "payload": {
            "mimeType": "multipart/related",
            "parts": [
              {
                "mimeType": "text/html",
                "body": {"data": "\(Data(html.utf8).base64EncodedString())"}
              },
              {
                "mimeType": "image/png",
                "headers": [{"name": "Content-ID", "value": "<image-001@example.com>"}],
                "body": {"attachmentId": "inline-png", "size": \(imageData.count)}
              }
            ]
          }
        }
        """
    )

    try await fixture.service.prefetchMessageBodies(
      connection: connection,
      pinnedMessageIds: [],
      referenceDate: Date(timeIntervalSince1970: 1_800_000_000),
      session: session
    )

    XCTAssertFalse(
      fixture.requestPaths.compactMap { $0 as? String }.contains {
        $0.contains("/attachments/")
      }
    )
    XCTAssertNil(
      try fixture.service.loadCachedMessageBody(message: prefetchedMessage, session: session)
    )
    XCTAssertEqual(
      fixture.requestQueries.compactMap { $0 as? String },
      ["format=metadata&metadataHeaders=Content-Type&metadataHeaders=Content-Disposition"]
    )

    let body = try await fixture.service.loadMessageBody(
      message: prefetchedMessage,
      session: session
    )

    XCTAssertEqual(body.inlineImages.map(\.contentID), ["image-001@example.com"])
    XCTAssertEqual(
      fixture.requestPaths.compactMap { $0 as? String }.filter {
        $0.contains("/attachments/")
      }.count,
      1
    )
    let requestCount = fixture.requestPaths.count

    let forwardedText = try await fixture.service.loadMessageBodyText(
      message: prefetchedMessage,
      session: session
    )

    XCTAssertEqual(forwardedText, body.text)
    XCTAssertEqual(fixture.requestPaths.count, requestCount)
  }

  func testTextOnlyReadDoesNotFetchMultipartBodyWithoutCachedText() async throws {
    let fixture = try makeFixture(
      prefetchMetadataResponse: """
        {
          "id": "message-001",
          "payload": {
            "mimeType": "multipart/related",
            "headers": [{"name": "Content-Type", "value": "multipart/related"}]
          }
        }
        """
    )

    do {
      _ = try await fixture.service.loadMessageBodyText(message: message, session: session)
      XCTFail("Expected unsafe multipart body to remain unopened")
    } catch GmailMessageBodyError.missingMessageBody {
      XCTAssertEqual(
        fixture.requestQueries.compactMap { $0 as? String },
        ["format=metadata&metadataHeaders=Content-Type&metadataHeaders=Content-Disposition"]
      )
      XCTAssertNil(fixture.cache.payload)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testReadRefetchesLegacyPlainTextPayloadThatLooksVersioned() async throws {
    let fixture = try makeFixture()
    fixture.cache.payload = try encryptedCachedBody(
      Data("unwired-gmail-body-cache-v1\n{\"html\":null,\"text\":\"Spoofed body\"}".utf8)
    )

    let body = try await fixture.service.loadMessageBody(message: message, session: session)

    XCTAssertEqual(body, GmailMessageBody(text: "Private trip details"))
    XCTAssertTrue(fixture.cache.didRemove)
    XCTAssertEqual(
      fixture.requestPaths, ["/token", "/tokeninfo", "/gmail/v1/users/me/messages/message-001"])
  }

  func testReadPropagatesCancellationInsteadOfReturningCachedUnresolvedHTML() async throws {
    let fixture = try makeFixture(messageError: CancellationError())
    fixture.cache.payload = try encryptedCachedBody(
      GmailMessageBodyCachePayload.encode(
        GmailMessageBody(
          text: "Cached receipt",
          html: #"<p>Cached receipt</p><img src="c&#105;d:logo@example.com">"#
        )
      ),
      versioned: true
    )
    XCTAssertFalse(
      try XCTUnwrap(
        fixture.service.loadCachedMessageBody(message: message, session: session)
      ).didResolveInlineImages
    )

    do {
      _ = try await fixture.service.loadMessageBody(message: message, session: session)
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      XCTAssertEqual(
        try fixture.service.loadCachedMessageBody(message: message, session: session)?.text,
        "Cached receipt"
      )
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testCachedReadRejectsMalformedVersionedPayload() throws {
    let fixture = try makeFixture()
    fixture.cache.payload = try encryptedCachedBody(
      Data("unwired-gmail-body-cache-v1\n{\"text\":".utf8),
      versioned: true
    )

    let body = try fixture.service.loadCachedMessageBody(message: message, session: session)

    XCTAssertNil(body)
    XCTAssertTrue(fixture.cache.didRemove)
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

  func testReconcileEnforcesMaximumByteCountForProtectedLegacyCache() throws {
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

    XCTAssertLessThanOrEqual(
      try cacheByteCount(rootDirectory: rootDirectory),
      encodedPayload.count
    )
  }

  func testReconcileScansCacheOnceForSelectionAndOnceForCapacity() throws {
    let rootDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let fileManager = CountingFileManager()
    let cache = FileGmailMessageBodyCache(
      fileManager: fileManager,
      maximumByteCount: .max,
      rootDirectory: rootDirectory
    )
    let payload = ProductSyncEncryptedPayload(
      algorithm: ProductSyncEncryptedPayload.algorithmName,
      ciphertextBase64: "ciphertext",
      keyVersion: 1,
      nonceBase64: "nonce",
      schemaVersion: 1,
      tagBase64: "tag"
    )
    let messageIds = [
      "gmail:gmail-user-001:message-001",
      "gmail:gmail-user-001:message-002",
    ]
    for messageId in messageIds {
      try cache.saveMessageBody(
        payload,
        productAccountId: session.productAccountId,
        stableProviderMessageId: messageId
      )
    }
    fileManager.contentsOfDirectoryCallCount = 0

    try cache.reconcileSelection(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: "gmail-user-001",
      protectedMessageIds: [messageIds[0]],
      pinnedMessageIds: [messageIds[1]]
    )

    XCTAssertEqual(fileManager.contentsOfDirectoryCallCount, 2)
  }

  func testReconcileSkipsLegacyEntryEvictedFromDirectorySnapshot() throws {
    let rootDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    let sizingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    defer {
      try? FileManager.default.removeItem(at: rootDirectory)
      try? FileManager.default.removeItem(at: sizingDirectory)
    }
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
    let maximumByteCount = try encodedCacheEntrySize(
      payload: payload,
      rootDirectory: sizingDirectory
    )
    let cache = FileGmailMessageBodyCache(
      maximumByteCount: maximumByteCount,
      rootDirectory: rootDirectory
    )

    try cache.reconcileSelection(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: "gmail-user-001",
      protectedMessageIds: [],
      pinnedMessageIds: []
    )

    XCTAssertLessThanOrEqual(
      try cacheByteCount(rootDirectory: rootDirectory),
      maximumByteCount
    )
  }

  func testPrefetchedBodyCanEvictProtectedCacheEntryWhenNecessary() throws {
    let rootDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    let sizingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    defer {
      try? FileManager.default.removeItem(at: rootDirectory)
      try? FileManager.default.removeItem(at: sizingDirectory)
    }
    let payload = ProductSyncEncryptedPayload(
      algorithm: ProductSyncEncryptedPayload.algorithmName,
      ciphertextBase64: String(repeating: "c", count: 128),
      keyVersion: 1,
      nonceBase64: "nonce",
      schemaVersion: 1,
      tagBase64: "tag"
    )
    let protectedMessageId = "gmail:gmail-user-001:protected"
    let incomingMessageId = "gmail:gmail-user-002:incoming"
    let unlimitedCache = FileGmailMessageBodyCache(
      maximumByteCount: .max,
      rootDirectory: rootDirectory
    )
    XCTAssertTrue(
      try unlimitedCache.saveMessageBody(
        cacheWrite(payload: payload, retention: .prefetched, cachedAt: 1),
        productAccountId: session.productAccountId,
        stableProviderMessageId: protectedMessageId
      )
    )
    try unlimitedCache.reconcileSelection(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: "gmail-user-001",
      protectedMessageIds: [protectedMessageId],
      pinnedMessageIds: []
    )

    let incomingSize = try encodedCacheEntrySize(payload: payload, rootDirectory: sizingDirectory)
    let cache = FileGmailMessageBodyCache(
      maximumByteCount: try cacheByteCount(rootDirectory: rootDirectory) + incomingSize - 1,
      rootDirectory: rootDirectory
    )
    XCTAssertTrue(
      try cache.saveMessageBody(
        cacheWrite(payload: payload, retention: .prefetched, cachedAt: 2),
        productAccountId: session.productAccountId,
        stableProviderMessageId: incomingMessageId
      )
    )
    XCTAssertNil(
      try cache.loadMessageBody(
        productAccountId: session.productAccountId,
        stableProviderMessageId: protectedMessageId
      )
    )
    XCTAssertNotNil(
      try cache.loadMessageBody(
        productAccountId: session.productAccountId,
        stableProviderMessageId: incomingMessageId
      )
    )
  }

  func testPrefetchExclusionCannotEvictProtectedCacheEntry() throws {
    let rootDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    defer {
      try? FileManager.default.removeItem(at: rootDirectory)
    }
    let payload = ProductSyncEncryptedPayload(
      algorithm: ProductSyncEncryptedPayload.algorithmName,
      ciphertextBase64: String(repeating: "c", count: 128),
      keyVersion: 1,
      nonceBase64: "nonce",
      schemaVersion: 1,
      tagBase64: "tag"
    )
    let protectedMessageId = "gmail:gmail-user-001:protected"
    let exclusionMessageId = "gmail:gmail-user-002:excluded"
    let unlimitedCache = FileGmailMessageBodyCache(
      maximumByteCount: .max,
      rootDirectory: rootDirectory
    )
    XCTAssertTrue(
      try unlimitedCache.saveMessageBody(
        cacheWrite(payload: payload, retention: .prefetched, cachedAt: 1),
        productAccountId: session.productAccountId,
        stableProviderMessageId: protectedMessageId
      )
    )
    try unlimitedCache.reconcileSelection(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: "gmail-user-001",
      protectedMessageIds: [protectedMessageId],
      pinnedMessageIds: []
    )

    let cache = FileGmailMessageBodyCache(
      maximumByteCount: try cacheByteCount(rootDirectory: rootDirectory),
      rootDirectory: rootDirectory
    )
    XCTAssertFalse(
      try cache.saveMessageBody(
        GmailMessageBodyCacheWrite(
          cachedAt: Date(timeIntervalSince1970: 2),
          isPinned: false,
          isProtected: true,
          payload: payload,
          retention: .prefetched,
          allowsProtectedEviction: false
        ),
        productAccountId: session.productAccountId,
        stableProviderMessageId: exclusionMessageId
      )
    )
    XCTAssertNotNil(
      try cache.loadMessageBody(
        productAccountId: session.productAccountId,
        stableProviderMessageId: protectedMessageId
      )
    )
    XCTAssertNil(
      try cache.loadMessageBody(
        productAccountId: session.productAccountId,
        stableProviderMessageId: exclusionMessageId
      )
    )
  }

  func testOpenedBodyReplacementPreservesProtectedPinnedSelection() throws {
    let rootDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let cache = FileGmailMessageBodyCache(
      maximumByteCount: .max,
      rootDirectory: rootDirectory
    )
    let originalPayload = ProductSyncEncryptedPayload(
      algorithm: ProductSyncEncryptedPayload.algorithmName,
      ciphertextBase64: "original",
      keyVersion: 1,
      nonceBase64: "nonce",
      schemaVersion: 1,
      tagBase64: "tag"
    )
    let replacementPayload = ProductSyncEncryptedPayload(
      algorithm: ProductSyncEncryptedPayload.algorithmName,
      ciphertextBase64: "replacement",
      keyVersion: 1,
      nonceBase64: "nonce",
      schemaVersion: 1,
      tagBase64: "tag"
    )
    XCTAssertTrue(
      try cache.saveMessageBody(
        GmailMessageBodyCacheWrite(
          cachedAt: .distantPast,
          isPinned: true,
          isProtected: true,
          payload: originalPayload,
          retention: .prefetched
        ),
        productAccountId: session.productAccountId,
        stableProviderMessageId: message.stableProviderMessageId
      )
    )

    try cache.saveMessageBody(
      replacementPayload,
      productAccountId: session.productAccountId,
      stableProviderMessageId: message.stableProviderMessageId
    )

    XCTAssertEqual(
      try cache.loadMessageBody(
        productAccountId: session.productAccountId,
        stableProviderMessageId: message.stableProviderMessageId
      ),
      replacementPayload
    )
    let metadataURL = bodyCacheURL(
      rootDirectory: rootDirectory,
      stableProviderMessageId: message.stableProviderMessageId
    ).deletingPathExtension()
      .appendingPathExtension("metadata")
      .appendingPathExtension("json")
    let metadata = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any]
    )
    XCTAssertEqual(metadata["isPinned"] as? Bool, true)
    XCTAssertEqual(metadata["isProtected"] as? Bool, true)
    XCTAssertEqual(metadata["retention"] as? String, GmailMessageBodyCacheRetention.opened.rawValue)
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

  func testFileCacheAdmissionUsesMetadataWithoutReadingUnrelatedPayloads() throws {
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
    let pinnedId = "gmail:gmail-user-002:pinned"
    let incomingId = "gmail:gmail-user-001:incoming"
    XCTAssertTrue(
      try unlimitedCache.saveMessageBody(
        cacheWrite(payload: payload, retention: .opened, cachedAt: 1),
        productAccountId: session.productAccountId,
        stableProviderMessageId: openedId
      )
    )
    XCTAssertTrue(
      try unlimitedCache.saveMessageBody(
        cacheWrite(payload: payload, retention: .prefetched, isPinned: true, cachedAt: 2),
        productAccountId: session.productAccountId,
        stableProviderMessageId: pinnedId
      )
    )
    let pinnedURL = bodyCacheURL(
      rootDirectory: rootDirectory,
      stableProviderMessageId: pinnedId
    )
    try Data("unreadable encrypted payload".utf8).write(to: pinnedURL)
    let incomingSize = try encodedCacheEntrySize(
      payload: payload,
      rootDirectory: sizingDirectory
    )

    try saveForcingOneEviction(
      payload: payload,
      stableProviderMessageId: incomingId,
      incomingSize: incomingSize,
      rootDirectory: rootDirectory
    )

    XCTAssertTrue(FileManager.default.fileExists(atPath: pinnedURL.path))
    XCTAssertNil(
      try unlimitedCache.loadMessageBody(
        productAccountId: session.productAccountId,
        stableProviderMessageId: openedId
      )
    )
    XCTAssertNotNil(
      try unlimitedCache.loadMessageBody(
        productAccountId: session.productAccountId,
        stableProviderMessageId: incomingId
      )
    )
  }

  func testFileCacheAccessUsesMetadataWithoutReadingUnrelatedPayloads() throws {
    let rootDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let cache = FileGmailMessageBodyCache(maximumByteCount: .max, rootDirectory: rootDirectory)
    let payload = ProductSyncEncryptedPayload(
      algorithm: ProductSyncEncryptedPayload.algorithmName,
      ciphertextBase64: String(repeating: "c", count: 128),
      keyVersion: 1,
      nonceBase64: "nonce",
      schemaVersion: 1,
      tagBase64: "tag"
    )
    let accessedId = "gmail:gmail-user-001:accessed"
    let unrelatedId = "gmail:gmail-user-002:unrelated"
    XCTAssertTrue(
      try cache.saveMessageBody(
        cacheWrite(payload: payload, retention: .prefetched, cachedAt: 1),
        productAccountId: session.productAccountId,
        stableProviderMessageId: accessedId
      )
    )
    XCTAssertTrue(
      try cache.saveMessageBody(
        cacheWrite(payload: payload, retention: .prefetched, isPinned: true, cachedAt: 2),
        productAccountId: session.productAccountId,
        stableProviderMessageId: unrelatedId
      )
    )
    let unrelatedURL = bodyCacheURL(
      rootDirectory: rootDirectory,
      stableProviderMessageId: unrelatedId
    )
    try Data("unreadable encrypted payload".utf8).write(to: unrelatedURL)

    try cache.recordMessageBodyAccess(
      productAccountId: session.productAccountId,
      stableProviderMessageId: accessedId,
      accessedAt: Date(timeIntervalSince1970: 3)
    )

    XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedURL.path))
  }

  func testFileCacheRejectsStaleMetadataAfterInterruptedBodyReplacement() throws {
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
    let replacedId = "gmail:gmail-user-001:replaced"
    let prefetchedId = "gmail:gmail-user-002:prefetched"
    XCTAssertTrue(
      try cache.saveMessageBody(
        cacheWrite(payload: payload, retention: .prefetched, isPinned: true, cachedAt: 2),
        productAccountId: session.productAccountId,
        stableProviderMessageId: replacedId
      )
    )
    try JSONEncoder().encode(payload).write(
      to: bodyCacheURL(
        rootDirectory: rootDirectory,
        stableProviderMessageId: replacedId
      ),
      options: [.atomic]
    )
    XCTAssertTrue(
      try cache.saveMessageBody(
        cacheWrite(payload: payload, retention: .prefetched, cachedAt: 1),
        productAccountId: session.productAccountId,
        stableProviderMessageId: prefetchedId
      )
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

    XCTAssertNil(
      try cache.loadMessageBody(
        productAccountId: session.productAccountId,
        stableProviderMessageId: replacedId
      )
    )
    XCTAssertNotNil(
      try cache.loadMessageBody(
        productAccountId: session.productAccountId,
        stableProviderMessageId: prefetchedId
      )
    )
  }

  func testFileCacheAdmissionPrunesOrphanedMetadataWithinMaximumByteCount() throws {
    let rootDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    let sizingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    defer {
      try? FileManager.default.removeItem(at: rootDirectory)
      try? FileManager.default.removeItem(at: sizingDirectory)
    }
    let payload = ProductSyncEncryptedPayload(
      algorithm: ProductSyncEncryptedPayload.algorithmName,
      ciphertextBase64: String(repeating: "c", count: 128),
      keyVersion: 1,
      nonceBase64: "nonce",
      schemaVersion: 1,
      tagBase64: "tag"
    )
    let orphanedId = "gmail:gmail-user-001:orphaned"
    let unlimitedCache = FileGmailMessageBodyCache(
      maximumByteCount: .max,
      rootDirectory: rootDirectory
    )
    XCTAssertTrue(
      try unlimitedCache.saveMessageBody(
        cacheWrite(payload: payload, retention: .prefetched, cachedAt: 1),
        productAccountId: session.productAccountId,
        stableProviderMessageId: orphanedId
      )
    )
    let orphanedBodyURL = bodyCacheURL(
      rootDirectory: rootDirectory,
      stableProviderMessageId: orphanedId
    )
    let orphanedMetadataURL = orphanedBodyURL.deletingPathExtension()
      .appendingPathExtension("metadata")
      .appendingPathExtension("json")
    try FileManager.default.removeItem(at: orphanedBodyURL)
    XCTAssertTrue(FileManager.default.fileExists(atPath: orphanedMetadataURL.path))

    let incomingSize = try encodedCacheEntrySize(
      payload: payload,
      rootDirectory: sizingDirectory
    )
    let cache = FileGmailMessageBodyCache(
      maximumByteCount: incomingSize,
      rootDirectory: rootDirectory
    )
    XCTAssertTrue(
      try cache.saveMessageBody(
        cacheWrite(payload: payload, retention: .prefetched, cachedAt: 2),
        productAccountId: session.productAccountId,
        stableProviderMessageId: "gmail:gmail-user-001:incoming"
      )
    )

    XCTAssertFalse(FileManager.default.fileExists(atPath: orphanedMetadataURL.path))
    XCTAssertLessThanOrEqual(
      try cacheByteCount(rootDirectory: rootDirectory),
      incomingSize
    )
  }

  func testFileCacheOverwriteReservesExistingLargerMetadataSidecar() throws {
    let rootDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    let sizingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    defer {
      try? FileManager.default.removeItem(at: rootDirectory)
      try? FileManager.default.removeItem(at: sizingDirectory)
    }
    let payload = ProductSyncEncryptedPayload(
      algorithm: ProductSyncEncryptedPayload.algorithmName,
      ciphertextBase64: String(repeating: "c", count: 128),
      keyVersion: 1,
      nonceBase64: "nonce",
      schemaVersion: 1,
      tagBase64: "tag"
    )
    let destinationId = "gmail:gmail-user-001:destination"
    let otherId = "gmail:gmail-user-002:other"
    let unlimitedCache = FileGmailMessageBodyCache(
      maximumByteCount: .max,
      rootDirectory: rootDirectory
    )
    for messageId in [destinationId, otherId] {
      XCTAssertTrue(
        try unlimitedCache.saveMessageBody(
          cacheWrite(payload: payload, retention: .prefetched, cachedAt: 1),
          productAccountId: session.productAccountId,
          stableProviderMessageId: messageId
        )
      )
    }
    let entrySize = try encodedCacheEntrySize(
      payload: payload,
      rootDirectory: sizingDirectory
    )
    let destinationURL = bodyCacheURL(
      rootDirectory: rootDirectory,
      stableProviderMessageId: destinationId
    )
    let destinationMetadataURL = destinationURL.deletingPathExtension()
      .appendingPathExtension("metadata")
      .appendingPathExtension("json")
    try Data(repeating: 0, count: entrySize).write(to: destinationMetadataURL)
    let cache = FileGmailMessageBodyCache(
      maximumByteCount: entrySize * 2,
      rootDirectory: rootDirectory
    )

    XCTAssertTrue(
      try cache.saveMessageBody(
        cacheWrite(payload: payload, retention: .prefetched, cachedAt: 1),
        productAccountId: session.productAccountId,
        stableProviderMessageId: destinationId
      )
    )

    XCTAssertNil(
      try cache.loadMessageBody(
        productAccountId: session.productAccountId,
        stableProviderMessageId: otherId
      )
    )
    XCTAssertLessThanOrEqual(
      try cacheByteCount(rootDirectory: rootDirectory),
      entrySize * 2
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
    labels: [String]?
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
    attachmentIdWithStatus: String = "html-001",
    attachmentResponses: [String: String] = [:],
    attachmentStatusCode: Int? = nil,
    hasKeyMaterial: Bool = true,
    metadataStore: GmailMessageMetadataPersisting = RecordingBodyPrefetchMetadataStore(),
    messageError: Error? = nil,
    messageStatusCode: Int = 200,
    prefetchMetadataResponse: String =
      """
    {
      "id": "message-001",
      "payload": {
        "mimeType": "text/plain",
        "headers": [{"name": "Content-Type", "value": "text/plain; charset=UTF-8"}]
      }
    }
    """,
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
    let requestQueries = NSMutableArray()
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
      if let query = request.url?.query {
        requestQueries.add(query)
      }
      if let attachmentStatusCode,
        request.url?.path.hasSuffix("/attachments/\(attachmentIdWithStatus)") == true
      {
        return (
          HTTPURLResponse(
            url: request.url!,
            statusCode: attachmentStatusCode,
            httpVersion: nil,
            headerFields: nil
          )!,
          Data()
        )
      }
      if let attachmentID = request.url?.path.split(separator: "/").last.map(String.init),
        let attachmentResponse = attachmentResponses[attachmentID],
        request.url?.path.contains("/attachments/") == true
      {
        XCTAssertEqual(
          request.value(forHTTPHeaderField: "Authorization"), "Bearer refreshed-access-token")
        return (
          HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
          )!,
          Data(attachmentResponse.utf8)
        )
      }
      if request.url?.query?.contains("format=metadata") == true {
        XCTAssertEqual(
          request.value(forHTTPHeaderField: "Authorization"), "Bearer refreshed-access-token"
        )
        XCTAssertEqual(
          request.url?.query,
          "format=metadata&metadataHeaders=Content-Type&metadataHeaders=Content-Disposition"
        )
        return (
          HTTPURLResponse(
            url: request.url!, statusCode: messageStatusCode, httpVersion: nil, headerFields: nil
          )!,
          Data(prefetchMetadataResponse.utf8)
        )
      }
      XCTAssertEqual(
        request.value(forHTTPHeaderField: "Authorization"), "Bearer refreshed-access-token")
      XCTAssertEqual(request.url?.query, "format=full")
      if let messageError {
        throw messageError
      }
      return (
        HTTPURLResponse(
          url: request.url!, statusCode: messageStatusCode, httpVersion: nil, headerFields: nil
        )!,
        Data(messageResponse.utf8)
      )
    }
    return GmailMessageBodyFixture(
      cache: cache,
      requestPaths: requestPaths,
      requestQueries: requestQueries,
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

  private func encryptedCachedBody(
    _ data: Data,
    versioned: Bool = false
  ) throws -> ProductSyncEncryptedPayload {
    let material = try ProductSyncKeyMaterial.create(
      accountKeyData: Data(repeating: 1, count: ProductSyncKeyMaterial.keyByteCount),
      recoveryKeyData: Data(repeating: 2, count: ProductSyncKeyMaterial.keyByteCount)
    )
    let associatedDataPrefix = versioned ? "gmail-body-cache-v1" : "gmail-body-cache"
    return try material.encryptPayload(
      data,
      associatedData: Data("\(associatedDataPrefix):\(message.stableProviderMessageId)".utf8)
    )
  }
}

private final class CountingFileManager: FileManager, @unchecked Sendable {
  var contentsOfDirectoryCallCount = 0

  override func contentsOfDirectory(
    at url: URL,
    includingPropertiesForKeys keys: [URLResourceKey]?,
    options mask: DirectoryEnumerationOptions = []
  ) throws -> [URL] {
    contentsOfDirectoryCallCount += 1
    return try super.contentsOfDirectory(
      at: url,
      includingPropertiesForKeys: keys,
      options: mask
    )
  }
}

private struct GmailMessageBodyFixture {
  let cache: RecordingGmailMessageBodyCache
  let requestPaths: NSMutableArray
  let requestQueries: NSMutableArray
  let service: GmailMessageBodyService
}

private final class RecordingGmailMessageBodyCache: GmailMessageBodyCaching {
  var allowsProtectedEviction: Bool?
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

  func clearMessageBodies(
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws {
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
    allowsProtectedEviction = write.allowsProtectedEviction
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

  func clearMessages(
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws {
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
