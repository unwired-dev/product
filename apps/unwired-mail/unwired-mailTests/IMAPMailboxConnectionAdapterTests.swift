import XCTest

@testable import unwired_mail

// swiftlint:disable file_length type_body_length

@MainActor
final class IMAPMailboxConnectionAdapterTests: XCTestCase {
  private let session = ProductAccountSessionSnapshot(
    appleUserIdentifier: "apple-user-001",
    identityToken: "identity-token",
    productAccountId: "product-account-001",
    trustedDeviceId: "trusted-device-001"
  )

  func testAuthorizedIMAPConnectionJoinsProviderNeutralConnectionList() async throws {
    let definition = imapDefinition(username: "reader")
    let authorizationStore = RecordingIMAPAuthorizationStore()
    authorizationStore.save(
      DeviceLocalGenericMailAuthorization(credential: "secret", definition: definition),
      productAccountId: ProductAccountId(session.productAccountId)
    )
    let adapter = try makeAdapter(
      authorizationStore: authorizationStore,
      client: RecordingIMAPClient(),
      definitions: [definition]
    )

    let connections = try await adapter.loadConnections(session: session)

    XCTAssertEqual(connections.count, 1)
    XCTAssertEqual(connections[0].authorizationState, .authorized)
    XCTAssertEqual(
      connections[0].capabilities,
      .imapFull(serverCapabilities: [])
    )
    XCTAssertEqual(connections[0].id, definition.connectionId)
  }

  func testSavedServerCapabilitiesDisableUnsafeActionsAndIDLE() async throws {
    let definition = imapDefinition(
      username: "limited",
      imapCapabilities: ["IMAP4REV1"]
    )
    let adapter = try makeAdapter(
      authorizationStore: authorizedStore(definition),
      client: RecordingIMAPClient(),
      definitions: [definition]
    )

    let connections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(connections.first)

    XCTAssertEqual(
      connection.capabilities.providerActions,
      [.markRead, .markUnread, .star, .unstar]
    )
    XCTAssertFalse(connection.capabilities.canRegisterPush)
    XCTAssertTrue(connection.capabilities.canSend)
  }

  func testMOVEOnlyServerDoesNotAdvertiseUnsafePermanentDelete() {
    let capabilities = MailboxConnectionCapabilities.imapFull(
      serverCapabilities: ["IMAP4REV1", "MOVE"]
    )

    XCTAssertTrue(capabilities.supports(.archive))
    XCTAssertTrue(capabilities.supports(.move))
    XCTAssertFalse(capabilities.supports(.delete))
  }

  func testSMTPDeliveryAndDraftAppendUseMappedMailboxes() async throws {
    let definition = imapDefinition(
      username: "sender",
      roleMappings: [
        .archive: "Archive",
        .drafts: "Brouillons",
        .sent: "Envoyés",
        .spam: "Spam",
        .trash: "Trash",
      ]
    )
    let client = RecordingIMAPClient()
    let smtpClient = RecordingSMTPMailClient()
    let adapter = try makeAdapter(
      authorizationStore: authorizedStore(definition),
      client: client,
      definitions: [definition],
      smtpClient: smtpClient
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(connections.first)
    let message = OutgoingMessage(
      body: "Héllo from IMAP",
      recipient: "\"Reader, Sr.\" <reader@example.com>, teammate@example.com",
      subject: "Mapped folders",
      inReplyTo: "<parent@example.com>",
      idempotencyKey: "delivery-1"
    )
    let draft = OutgoingMessage(
      body: "Unfinished",
      recipient: "",
      subject: "Draft without recipient"
    )

    try await adapter.send(message, connection: connection, session: session)
    try await adapter.saveDraft(draft, connection: connection, session: session)

    XCTAssertEqual(smtpClient.sentMessages.count, 1)
    XCTAssertEqual(
      smtpClient.envelopeRecipients,
      [["reader@example.com", "teammate@example.com"]]
    )
    XCTAssertEqual(client.appendedMessages.map(\.mailbox), ["Envoyés", "Brouillons"])
    XCTAssertEqual(client.appendedMessages.map(\.flags), [["\\Seen"], ["\\Draft"]])
    let submitted = try XCTUnwrap(String(data: smtpClient.sentMessages[0], encoding: .utf8))
    XCTAssertTrue(submitted.contains("Message-ID: <delivery-1@outbox.unwired.mail>"))
    XCTAssertTrue(submitted.contains("In-Reply-To: <parent@example.com>"))
    XCTAssertTrue(submitted.contains("Content-Transfer-Encoding: base64"))
    XCTAssertTrue(submitted.contains(Data("Héllo from IMAP".utf8).base64EncodedString()))
    let savedDraft = try XCTUnwrap(
      String(data: client.appendedMessages[1].message, encoding: .utf8)
    )
    XCTAssertFalse(savedDraft.contains("\r\nTo:"))
  }

  func testSentCopyFailureIsReportedAfterSMTPAcceptance() async throws {
    let definition = imapDefinition(username: "sender")
    let client = RecordingIMAPClient()
    client.failsAppend = true
    let smtpClient = RecordingSMTPMailClient()
    let adapter = try makeAdapter(
      authorizationStore: authorizedStore(definition),
      client: client,
      definitions: [definition],
      smtpClient: smtpClient
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(connections.first)

    do {
      try await adapter.send(
        OutgoingMessage(
          body: "Accepted once",
          recipient: "reader@example.com",
          subject: "Partial failure"
        ),
        connection: connection,
        session: session
      )
      XCTFail("Expected the missing Sent copy to be reported")
    } catch {
      XCTAssertEqual(error as? SMTPMailError, .sentCopyFailedAfterAcceptance)
    }
    client.failsAppend = false
    try await adapter.send(
      OutgoingMessage(
        body: "Accepted once",
        recipient: "reader@example.com",
        subject: "Partial failure",
        sentCopyOnly: true
      ),
      connection: connection,
      session: session
    )
    XCTAssertEqual(smtpClient.sentMessages.count, 1)
    XCTAssertEqual(client.appendedMessages.count, 1)
  }

  func testUnknownSentCopyOutcomeReconcilesAgainstRemoteSentMailbox() async throws {
    let definition = imapDefinition(username: "sender")
    let client = RecordingIMAPClient()
    client.appendError = IMAPMailboxError.appendOutcomeUnknown
    let smtpClient = RecordingSMTPMailClient()
    let adapter = try makeAdapter(
      authorizationStore: authorizedStore(definition),
      client: client,
      definitions: [definition],
      smtpClient: smtpClient
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(connections.first)
    let message = OutgoingMessage(
      body: "Accepted once",
      recipient: "reader@example.com",
      subject: "Unknown Sent copy",
      idempotencyKey: "delivery-unknown-copy"
    )

    do {
      try await adapter.send(message, connection: connection, session: session)
      XCTFail("Expected an unknown Sent-copy result")
    } catch {
      XCTAssertEqual(
        error as? SMTPMailError,
        .sentCopyOutcomeUnknownAfterAcceptance
      )
    }
    let unresolvedStatus = try await adapter.deliveryStatus(
      idempotencyKey: "delivery-unknown-copy",
      connection: connection,
      session: session
    )
    XCTAssertEqual(unresolvedStatus, .unknown)
    client.messagesByUsernameAndMailbox[definition.username] = [
      "Sent": [
        imapMessage(
          mailbox: "Sent",
          uid: 10,
          rfcMessageId: "<delivery-unknown-copy@outbox.unwired.mail>"
        )
      ]
    ]

    let status = try await adapter.deliveryStatus(
      idempotencyKey: "delivery-unknown-copy",
      connection: connection,
      session: session
    )

    XCTAssertEqual(status, .sent)
    XCTAssertEqual(smtpClient.sentMessages.count, 1)
  }

  func testOfflineActionPersistsThenResumesThroughIMAPClient() async throws {
    let definition = imapDefinition(username: "reader")
    let client = RecordingIMAPClient()
    client.messagesByUsername[definition.username] = [imapMessage(uid: 7)]
    let pendingStore = RecordingPendingProviderActionStore()
    let adapter = try makeAdapter(
      authorizationStore: authorizedStore(definition),
      client: client,
      definitions: [definition],
      pendingStore: pendingStore
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(connections.first)
    let syncResult = try await adapter.syncInbox(connection: connection, session: session)
    let message = try XCTUnwrap(syncResult.messages.first)

    try await adapter.perform(
      .markRead,
      messages: [message],
      connection: connection,
      session: session
    )

    XCTAssertEqual(
      try pendingStore.load(productAccountId: session.productAccountId).count,
      1
    )
    XCTAssertTrue(client.performedActions.isEmpty)

    let resumeError = await adapter.resumePendingActions(
      connection: connection,
      session: session
    )
    XCTAssertNil(resumeError)

    XCTAssertEqual(client.performedActions.map(\.action), [.markRead])
    XCTAssertEqual(
      try pendingStore.load(productAccountId: session.productAccountId).first?.state,
      .providerConfirmed
    )
    client.messagesByUsername[definition.username] = [
      imapMessage(uid: 7, flags: ["\\Seen"])
    ]
    _ = try await adapter.syncInbox(connection: connection, session: session)
    XCTAssertTrue(
      try pendingStore.load(productAccountId: session.productAccountId).isEmpty
    )
  }

  func testIDLERegistrationAndChangeWaitUseIMAPClient() async throws {
    let definition = imapDefinition(
      username: "idle",
      imapCapabilities: ["IDLE", "MOVE"]
    )
    let client = RecordingIMAPClient()
    client.supportsIdleResult = true
    let adapter = try makeAdapter(
      authorizationStore: authorizedStore(definition),
      client: client,
      definitions: [definition]
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(connections.first)

    try await adapter.registerOrRenewPush(connection: connection, session: session)
    try await adapter.waitForMailboxChange(connection: connection, session: session)

    XCTAssertEqual(client.supportsIdleRequestCount, 1)
    XCTAssertEqual(client.waitedMailboxes, ["INBOX"])
    XCTAssertTrue(connection.capabilities.canRegisterPush)
  }

  func testInitialFiftyMessagesRemainUsableWhileBackfillResumesAfterRecreation() async throws {
    let definition = imapDefinition(username: "reader")
    let authorizationStore = authorizedStore(definition)
    let client = RecordingIMAPClient()
    client.messagesByUsername[definition.username] = (1...75).map {
      imapMessage(uid: Int64($0), subject: "Message \($0)")
    }
    let store = try SwiftDataIMAPMessageMetadataStore.inMemory()
    let adapter = try makeAdapter(
      authorizationStore: authorizationStore,
      client: client,
      definitions: [definition],
      store: store
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(connections.first)

    let initial = try await adapter.syncInbox(connection: connection, session: session)

    XCTAssertTrue(initial.hasInitialMailboxAvailability)
    XCTAssertFalse(initial.historicalMetadataBackfillIsComplete)
    XCTAssertEqual(initial.messages.count, 50)
    XCTAssertEqual(initial.messages.first?.subject, "Message 75")
    client.messagesByUsername[definition.username]?.append(
      imapMessage(uid: 76, subject: "Message 76")
    )

    let recreatedAdapter = try makeAdapter(
      authorizationStore: authorizationStore,
      client: client,
      definitions: [definition],
      store: store
    )
    let resumedInitial = try await recreatedAdapter.syncInbox(
      connection: connection,
      session: session
    )

    XCTAssertEqual(resumedInitial.messages.count, 50)
    XCTAssertEqual(resumedInitial.messages.first?.subject, "Message 76")
    XCTAssertEqual(client.metadataRequestCount, 2)

    let completed = try await recreatedAdapter.continueHistoricalBackfill(
      connection: connection,
      session: session
    )

    XCTAssertTrue(completed.historicalMetadataBackfillIsComplete)
    XCTAssertEqual(completed.messages.count, 76)

    client.messagesByUsername[definition.username]?.append(
      imapMessage(uid: 77, subject: "Message 77")
    )

    let refreshed = try await recreatedAdapter.syncInbox(connection: connection, session: session)

    XCTAssertTrue(refreshed.historicalMetadataBackfillIsComplete)
    XCTAssertEqual(refreshed.messages.count, 77)
    XCTAssertEqual(refreshed.messages.last?.subject, "Message 1")
  }

  func testInitialAvailabilityKeepsEachMailboxsFirstPageUsable() async throws {
    let definition = imapDefinition(username: "reader")
    let authorizationStore = authorizedStore(definition)
    let client = RecordingIMAPClient()
    client.mailboxesByUsername[definition.username] = [
      IMAPMailboxDescriptor(displayName: "Inbox", name: "INBOX"),
      IMAPMailboxDescriptor(displayName: "Archive", name: "Archive"),
    ]
    client.messagesByUsernameAndMailbox[definition.username] = [
      "INBOX": (1...60).map { imapMessage(uid: Int64($0)) },
      "Archive": (61...120).map {
        imapMessage(mailbox: "Archive", uid: Int64($0))
      },
    ]
    let adapter = try makeAdapter(
      authorizationStore: authorizationStore,
      client: client,
      definitions: [definition]
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(connections.first)

    let initial = try await adapter.syncInbox(connection: connection, session: session)
    let archive = try await adapter.loadMailbox(
      .role(.archive),
      connection: connection,
      session: session
    )

    XCTAssertEqual(initial.messages.count, 50)
    XCTAssertEqual(initial.messages.first?.providerInternalDateMilliseconds, 1_781_200_000_060)
    XCTAssertEqual(archive.messages.count, 50)
    XCTAssertEqual(archive.messages.first?.providerInternalDateMilliseconds, 1_781_200_000_120)
    XCTAssertFalse(initial.historicalMetadataBackfillIsComplete)
  }

  func testRefreshDropsRecordsFromRemovedMailboxBeforeBackfillCompletes() async throws {
    let definition = imapDefinition(username: "reader")
    let authorizationStore = authorizedStore(definition)
    let client = RecordingIMAPClient()
    client.mailboxesByUsername[definition.username] = [
      IMAPMailboxDescriptor(displayName: "Inbox", name: "INBOX"),
      IMAPMailboxDescriptor(displayName: "Archive", name: "Archive"),
    ]
    client.messagesByUsernameAndMailbox[definition.username] = [
      "INBOX": (1...60).map { imapMessage(uid: Int64($0)) },
      "Archive": (61...120).map {
        imapMessage(mailbox: "Archive", uid: Int64($0))
      },
    ]
    let adapter = try makeAdapter(
      authorizationStore: authorizationStore,
      client: client,
      definitions: [definition]
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(connections.first)

    _ = try await adapter.syncInbox(connection: connection, session: session)
    client.mailboxesByUsername[definition.username] = [
      IMAPMailboxDescriptor(displayName: "Inbox", name: "INBOX")
    ]

    let refreshed = try await adapter.syncInbox(connection: connection, session: session)
    let observed = try await adapter.loadMailbox(
      .allObserved,
      connection: connection,
      session: session
    )

    XCTAssertFalse(refreshed.historicalMetadataBackfillIsComplete)
    XCTAssertEqual(refreshed.messages.count, 50)
    XCTAssertEqual(observed.messages.count, 50)
  }

  func testObjectIdDeduplicatesOneMessageAcrossMailboxes() async throws {
    let definition = imapDefinition(username: "reader")
    let authorizationStore = authorizedStore(definition)
    let client = RecordingIMAPClient()
    client.mailboxesByUsername[definition.username] = [
      IMAPMailboxDescriptor(displayName: "Inbox", name: "INBOX"),
      IMAPMailboxDescriptor(displayName: "Archive", name: "Archive"),
    ]
    client.messagesByUsernameAndMailbox[definition.username] = [
      "INBOX": [
        imapMessage(uid: 1, providerEmailId: "shared-email")
      ],
      "Archive": [
        imapMessage(mailbox: "Archive", uid: 8, providerEmailId: "shared-email")
      ],
    ]
    let adapter = try makeAdapter(
      authorizationStore: authorizationStore,
      client: client,
      definitions: [definition]
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(connections.first)

    let result = try await adapter.syncInbox(connection: connection, session: session)

    XCTAssertEqual(result.messages.count, 1)
    XCTAssertEqual(result.messages.first?.providerMessageId, "imap-email:shared-email")
    XCTAssertEqual(
      Set(result.messages.first?.providerStateIds ?? []), ["INBOX", "ARCHIVE", "UNREAD"])
  }

  func testProviderActionUsesInboxAppearanceForMessageObservedInMultipleMailboxes() async throws {
    let definition = imapDefinition(username: "reader")
    let client = RecordingIMAPClient()
    client.mailboxesByUsername[definition.username] = [
      IMAPMailboxDescriptor(displayName: "Inbox", name: "INBOX"),
      IMAPMailboxDescriptor(displayName: "Archive", name: "Archive"),
    ]
    client.messagesByUsernameAndMailbox[definition.username] = [
      "INBOX": [
        imapMessage(uid: 1, providerEmailId: "shared-email")
      ],
      "Archive": [
        imapMessage(mailbox: "Archive", uid: 8, providerEmailId: "shared-email")
      ],
    ]
    let adapter = try makeAdapter(
      authorizationStore: authorizedStore(definition),
      client: client,
      definitions: [definition]
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(connections.first)
    let syncResult = try await adapter.syncInbox(connection: connection, session: session)
    let message = try XCTUnwrap(syncResult.messages.first)

    try await adapter.perform(
      .archive,
      messages: [message],
      connection: connection,
      session: session
    )
    _ = await adapter.resumePendingActions(connection: connection, session: session)

    XCTAssertEqual(client.performedActions.map(\.uid), [1])
  }

  // swiftlint:disable:next function_body_length
  func testSavedRolesAndRFCLinkageDriveProjectionWithoutSubjectMerging() async throws {
    let definition = imapDefinition(
      username: "reader",
      roleMappings: [
        .archive: "Archive",
        .drafts: "Drafts",
        .sent: "Sent Items",
        .spam: "Junk",
        .trash: "Deleted",
      ]
    )
    let authorizationStore = authorizedStore(definition)
    let client = RecordingIMAPClient()
    client.mailboxesByUsername[definition.username] = [
      IMAPMailboxDescriptor(displayName: "Inbox", name: "INBOX"),
      IMAPMailboxDescriptor(displayName: "Sent Items", name: "Sent Items"),
    ]
    client.messagesByUsernameAndMailbox[definition.username] = [
      "INBOX": [
        imapMessage(
          uid: 1,
          rfcMessageId: "<root@example.com>",
          subject: "Shared subject"
        ),
        imapMessage(
          uid: 2,
          inReplyTo: "<root@example.com>",
          references: ["<root@example.com>"],
          rfcMessageId: "<reply@example.com>",
          subject: "Re: Shared subject"
        ),
        imapMessage(
          uid: 3,
          inReplyTo: "<reply@example.com>",
          rfcMessageId: "<second-reply@example.com>",
          subject: "Re: Re: Shared subject"
        ),
        imapMessage(
          uid: 4,
          rfcMessageId: "<unrelated@example.com>",
          subject: "Shared subject"
        ),
      ],
      "Sent Items": [
        imapMessage(
          mailbox: "Sent Items",
          uid: 5,
          rfcMessageId: "<sent@example.com>",
          subject: "Sent"
        )
      ],
    ]
    let adapter = try makeAdapter(
      authorizationStore: authorizationStore,
      client: client,
      definitions: [definition]
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(connections.first)
    _ = try await adapter.syncInbox(connection: connection, session: session)

    let inbox = try await adapter.loadMailbox(
      .role(.inbox),
      connection: connection,
      session: session
    )
    let sent = try await adapter.loadMailbox(
      .role(.sent),
      connection: connection,
      session: session
    )

    XCTAssertEqual(inbox.messages.count, 4)
    XCTAssertEqual(inbox.threads.map(\.messages.count).sorted(), [1, 3])
    XCTAssertEqual(sent.messages.map(\.subject), ["Sent"])
    XCTAssertTrue((sent.messages.first?.providerStateIds ?? []).contains("SENT"))
  }

  func testUIDValidityChangeAndExpungeRemoveOnlyAffectedConnectionRecords() async throws {
    let definition = imapDefinition(username: "reader")
    let authorizationStore = authorizedStore(definition)
    let client = RecordingIMAPClient()
    client.messagesByUsername[definition.username] = [
      imapMessage(uid: 1, subject: "First"),
      imapMessage(uid: 2, subject: "Second"),
    ]
    let store = try SwiftDataIMAPMessageMetadataStore.inMemory()
    let adapter = try makeAdapter(
      authorizationStore: authorizationStore,
      client: client,
      definitions: [definition],
      store: store
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(connections.first)
    _ = try await adapter.syncInbox(connection: connection, session: session)

    client.uidValidityByUsername[definition.username] = 2
    client.messagesByUsername[definition.username] = [
      imapMessage(uid: 1, uidValidity: 2, subject: "Replacement")
    ]
    let reset = try await adapter.syncInbox(connection: connection, session: session)

    XCTAssertEqual(reset.messages.map(\.subject), ["Replacement"])

    client.messagesByUsername[definition.username] = []
    let expunged = try await adapter.syncInbox(connection: connection, session: session)

    XCTAssertTrue(expunged.messages.isEmpty)
  }

  func testCompletedBackfillRemovesAnExpungedMessageInRefreshedPage() async throws {
    let definition = imapDefinition(username: "reader")
    let authorizationStore = authorizedStore(definition)
    let client = RecordingIMAPClient()
    client.messagesByUsername[definition.username] = (1...75).map {
      imapMessage(uid: Int64($0), subject: "Message \($0)")
    }
    let adapter = try makeAdapter(
      authorizationStore: authorizationStore,
      client: client,
      definitions: [definition]
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(connections.first)

    _ = try await adapter.syncInbox(connection: connection, session: session)
    _ = try await adapter.continueHistoricalBackfill(connection: connection, session: session)
    client.messagesByUsername[definition.username]?.removeAll { $0.uid == 26 }

    let refreshed = try await adapter.syncInbox(connection: connection, session: session)

    XCTAssertEqual(refreshed.messages.count, 74)
    XCTAssertFalse(refreshed.messages.contains { $0.subject == "Message 26" })
  }

  func testCustomMailboxStateIdsAreNamespacedAndCaseSensitive() {
    let definition = imapDefinition(username: "reader", roleMappings: [.archive: "Projects"])
    let message = imapMessage(mailbox: "projects", uid: 1)

    let metadata = message.mailboxMetadata(
      connectionId: definition.connectionId,
      connectedAt: 0,
      roleMappings: definition.roleMappings
    )
    let customMailboxId = IMAPProviderMessage.customMailboxStateId("projects")

    XCTAssertFalse((metadata.providerStateIds ?? []).contains("ARCHIVE"))
    XCTAssertTrue((metadata.providerStateIds ?? []).contains(customMailboxId))
    XCTAssertTrue(
      MailboxMessageCollection.providerMailbox(customMailboxId)
        .contains(providerStateIds: metadata.providerStateIds)
    )
    XCTAssertFalse(
      MailboxMessageCollection.role(.archive)
        .contains(providerStateIds: metadata.providerStateIds)
    )
  }

  func testCancelledBackfillPersistsCompletedPagesAndResumesWithoutDuplicates() async throws {
    let definition = imapDefinition(username: "reader")
    let authorizationStore = authorizedStore(definition)
    let client = RecordingIMAPClient()
    client.messagesByUsername[definition.username] = (1...120).map {
      imapMessage(uid: Int64($0), subject: "Message \($0)")
    }
    client.failOnMetadataRequest = 3
    let store = try SwiftDataIMAPMessageMetadataStore.inMemory()
    let adapter = try makeAdapter(
      authorizationStore: authorizationStore,
      client: client,
      definitions: [definition],
      store: store
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(connections.first)
    _ = try await adapter.syncInbox(connection: connection, session: session)

    do {
      _ = try await adapter.continueHistoricalBackfill(
        connection: connection,
        session: session
      )
      XCTFail("Expected cancellation")
    } catch is CancellationError {
    }
    let persisted = try await adapter.loadMailbox(
      .allObserved,
      connection: connection,
      session: session
    )
    XCTAssertEqual(persisted.messages.count, 100)

    client.failOnMetadataRequest = nil
    let completed = try await adapter.continueHistoricalBackfill(
      connection: connection,
      session: session
    )

    XCTAssertEqual(completed.messages.count, 120)
    XCTAssertEqual(Set(completed.messages.map(\.stableProviderMessageId)).count, 120)
    XCTAssertEqual(client.metadataRequestCount, 4)
  }

  func testConnectionsRemainIsolatedAcrossSynchronization() async throws {
    let firstDefinition = imapDefinition(username: "first")
    let secondDefinition = imapDefinition(username: "second")
    let authorizationStore = RecordingIMAPAuthorizationStore()
    for definition in [firstDefinition, secondDefinition] {
      authorizationStore.save(
        DeviceLocalGenericMailAuthorization(credential: "secret", definition: definition),
        productAccountId: ProductAccountId(session.productAccountId)
      )
    }
    let client = RecordingIMAPClient()
    client.messagesByUsername[firstDefinition.username] = [
      imapMessage(uid: 1, subject: "First account")
    ]
    client.messagesByUsername[secondDefinition.username] = [
      imapMessage(uid: 1, subject: "Second account")
    ]
    let adapter = try makeAdapter(
      authorizationStore: authorizationStore,
      client: client,
      definitions: [firstDefinition, secondDefinition]
    )
    let connections = try await adapter.loadConnections(session: session)
    for connection in connections {
      _ = try await adapter.syncInbox(connection: connection, session: session)
    }

    let results = try await connections.asyncMap { connection in
      try await adapter.loadMailbox(
        .allObserved,
        connection: connection,
        session: session
      )
    }

    XCTAssertEqual(results.map { $0.messages.count }, [1, 1])
    XCTAssertEqual(
      Set(results.flatMap(\.messages).map(\.connectionId)),
      Set(connections.map(\.id))
    )
  }

  func testOpenedBodyUsesSharedEncryptedCacheAcrossAdapterRecreation() async throws {
    let definition = imapDefinition(username: "reader")
    let authorizationStore = authorizedStore(definition)
    let client = RecordingIMAPClient()
    client.messagesByUsername[definition.username] = [imapMessage(uid: 1)]
    client.bodyByUID[1] = "Private body"
    let store = try SwiftDataIMAPMessageMetadataStore.inMemory()
    let rootDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let cache = FileGmailMessageBodyCache(rootDirectory: rootDirectory)
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    let adapter = try makeAdapter(
      authorizationStore: authorizationStore,
      cache: cache,
      client: client,
      definitions: [definition],
      keyStore: keyStore,
      store: store
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(connections.first)
    let synced = try await adapter.syncInbox(connection: connection, session: session)
    let message = try XCTUnwrap(synced.messages.first)

    let first = try await adapter.loadMessageBody(message: message, session: session)
    let recreated = try makeAdapter(
      authorizationStore: authorizationStore,
      cache: cache,
      client: client,
      definitions: [definition],
      keyStore: keyStore,
      store: store
    )
    try authorizationStore.remove(
      productAccountId: ProductAccountId(session.productAccountId),
      connectionId: connection.id
    )
    let second = try await recreated.loadMessageBody(message: message, session: session)

    XCTAssertEqual(first.text, "Private body")
    XCTAssertEqual(second, first)
    XCTAssertEqual(client.bodyRequestCount, 1)
  }

  func testRepresentativeServerListTranscripts() async throws {
    let transcripts: [(String, String)] = [
      (#"* LIST (\HasNoChildren) "/" "INBOX""#, "INBOX"),
      (#"* LIST (\HasChildren) "/" "Projects""#, "Projects"),
      (#"* LIST (\HasNoChildren) "." "&AMk-l&AOk-ments""#, "Éléments"),
    ]
    for (listLine, expectedName) in transcripts {
      let task = TranscriptIMAPStreamTask(
        responses: [
          "* OK ready\r\n",
          "A1 OK authenticated\r\n",
          "\(listLine)\r\nA2 OK listed\r\n",
        ]
      )
      let client = SystemIMAPMailboxClient(
        streamTaskFactory: TranscriptIMAPStreamTaskFactory(tasks: [task])
      )

      let mailboxes = try await client.listMailboxes(
        authorization: DeviceLocalGenericMailAuthorization(
          credential: "secret",
          definition: imapDefinition(username: "reader")
        )
      )

      XCTAssertEqual(mailboxes.map(\.displayName), [expectedName])
    }
  }

  func testSystemClientFetchesTextPartWithoutDownloadingAttachment() async throws {
    let bodyStructure =
      #"* 1 FETCH (UID 7 BODYSTRUCTURE (("TEXT" "PLAIN" ("CHARSET" "UTF-8") "#
      + #"NIL NIL "QUOTED-PRINTABLE" 12 1 NIL NIL NIL)("APPLICATION" "PDF" "#
      + #"("NAME" "file.pdf") NIL NIL "BASE64" 100 NIL "#
      + #"("ATTACHMENT" ("FILENAME" "file.pdf")) NIL) "MIXED"))"#
    let task = TranscriptIMAPStreamTask(
      responses: [
        "* OK ready\r\n",
        "A1 OK authenticated\r\n",
        "* OK [UIDVALIDITY 1] selected\r\nA2 OK selected\r\n",
        "\(bodyStructure)\r\nA3 OK structure\r\n",
        "* 1 FETCH (UID 7 BODY[1] {12}\r\nHello=20IMAP)\r\nA4 OK body\r\n",
      ]
    )
    let definition = imapDefinition(username: "reader")
    let client = SystemIMAPMailboxClient(
      streamTaskFactory: TranscriptIMAPStreamTaskFactory(tasks: [task])
    )

    let body = try await client.loadTextBody(
      message: imapMessage(uid: 7),
      authorization: DeviceLocalGenericMailAuthorization(
        credential: "secret",
        definition: definition
      )
    )

    XCTAssertEqual(body, "Hello IMAP")
    XCTAssertTrue(task.writes.contains { $0.contains("BODY.PEEK[1]") })
    XCTAssertFalse(task.writes.contains { $0.contains("BODY.PEEK[2]") })
  }

  func testSystemClientPreservesNonUTF8BodyLiteralBytes() async throws {
    let bodyStructure =
      #"* 1 FETCH (UID 7 BODYSTRUCTURE ("TEXT" "PLAIN" ("CHARSET" "ISO-8859-1") "#
      + #"NIL NIL "8BIT" 1 1 NIL NIL NIL))"#
    var bodyResponse = Data("* 1 FETCH (UID 7 BODY[1] {1}\r\n".utf8)
    bodyResponse.append(0xE9)
    bodyResponse.append(Data(")\r\nA4 OK body\r\n".utf8))
    let task = TranscriptIMAPStreamTask(
      responsesData: [
        Data("* OK ready\r\n".utf8),
        Data("A1 OK authenticated\r\n".utf8),
        Data("* OK [UIDVALIDITY 1] selected\r\nA2 OK selected\r\n".utf8),
        Data("\(bodyStructure)\r\nA3 OK structure\r\n".utf8),
        bodyResponse,
      ]
    )
    let client = SystemIMAPMailboxClient(
      streamTaskFactory: TranscriptIMAPStreamTaskFactory(tasks: [task])
    )

    let body = try await client.loadTextBody(
      message: imapMessage(uid: 7),
      authorization: DeviceLocalGenericMailAuthorization(
        credential: "secret",
        definition: imapDefinition(username: "reader")
      )
    )

    XCTAssertEqual(body, "é")
  }

  func testSystemClientUsesObjectIdForStableIdentityAndThreading() async throws {
    let headers = "Message-ID: <fallback@example.com>\r\nSubject: Object identity\r\n"
    let fetch =
      "* 1 FETCH (UID 7 FLAGS (\\Seen) INTERNALDATE \" 7-Jul-2026 09:00:00 +0000\" "
      + "EMAILID (email-7) THREADID (thread-4) "
      + "BODY[HEADER.FIELDS (CC FROM IN-REPLY-TO MESSAGE-ID REFERENCES REPLY-TO SUBJECT TO)] "
      + "{\(headers.utf8.count)}\r\n\(headers))\r\nA5 OK fetched\r\n"
    let task = TranscriptIMAPStreamTask(
      responses: [
        "* OK ready\r\n",
        "A1 OK authenticated\r\n",
        "* CAPABILITY IMAP4rev1 OBJECTID\r\nA2 OK capable\r\n",
        "* OK [UIDVALIDITY 9] selected\r\nA3 OK selected\r\n",
        "* SEARCH 7\r\nA4 OK searched\r\n",
        fetch,
      ]
    )
    let client = SystemIMAPMailboxClient(
      streamTaskFactory: TranscriptIMAPStreamTaskFactory(tasks: [task])
    )

    let page = try await client.loadMetadataPage(
      mailbox: IMAPMailboxDescriptor(displayName: "Inbox", name: "INBOX"),
      beforeUID: nil,
      limit: 50,
      authorization: DeviceLocalGenericMailAuthorization(
        credential: "secret",
        definition: imapDefinition(username: "reader")
      )
    )

    XCTAssertEqual(page.messages.first?.providerMessageId, "imap-email:email-7")
    XCTAssertEqual(page.messages.first?.providerThreadId, "thread-4")
    XCTAssertTrue(task.writes.contains { $0.contains("EMAILID THREADID") })
  }

  func testSystemClientUsesServerMOVEWithoutUnsafeExpunge() async throws {
    let task = TranscriptIMAPStreamTask(
      responses: [
        "* OK ready\r\n",
        "A1 OK authenticated\r\n",
        "* CAPABILITY IMAP4rev1 MOVE\r\nA2 OK capable\r\n",
        "* OK [UIDVALIDITY 1] selected\r\nA3 OK selected\r\n",
        "A4 OK moved\r\n",
      ]
    )
    let definition = imapDefinition(username: "reader")
    let client = SystemIMAPMailboxClient(
      streamTaskFactory: TranscriptIMAPStreamTaskFactory(tasks: [task])
    )

    try await client.perform(
      .archive,
      message: imapMessage(uid: 7),
      targetMailbox: "Archive",
      authorization: DeviceLocalGenericMailAuthorization(
        credential: "secret",
        definition: definition
      )
    )

    XCTAssertTrue(task.writes.contains("A4 UID MOVE 7 \"Archive\"\r\n"))
    XCTAssertFalse(task.writes.contains { $0.contains("EXPUNGE") })
  }

  // swiftlint:disable:next function_body_length
  func testSystemClientReconcilesUIDPLUSCopyBeforeRetryingMove() async throws {
    let firstTask = TranscriptIMAPStreamTask(
      responses: [
        .success("* OK ready\r\n"),
        .success("A1 OK authenticated\r\n"),
        .success("* CAPABILITY IMAP4rev1 UIDPLUS\r\nA2 OK capable\r\n"),
        .success("* OK [UIDVALIDITY 1] selected\r\nA3 OK selected\r\n"),
        .success("* OK [UIDVALIDITY 8] selected\r\nA4 OK selected\r\n"),
        .success("* SEARCH\r\nA5 OK searched\r\n"),
        .success("* OK [UIDVALIDITY 1] selected\r\nA6 OK selected\r\n"),
        .success("A7 OK [COPYUID 8 7 42] copied\r\n"),
        .failure(URLError(.networkConnectionLost)),
      ]
    )
    let retryTask = TranscriptIMAPStreamTask(
      responses: [
        "* OK ready\r\n",
        "A1 OK authenticated\r\n",
        "* CAPABILITY IMAP4rev1 UIDPLUS\r\nA2 OK capable\r\n",
        "* OK [UIDVALIDITY 1] selected\r\nA3 OK selected\r\n",
        "* OK [UIDVALIDITY 8] selected\r\nA4 OK selected\r\n",
        "* SEARCH 42\r\nA5 OK searched\r\n",
        "* OK [UIDVALIDITY 1] selected\r\nA6 OK selected\r\n",
        "A7 OK stored\r\n",
        "A8 OK expunged\r\n",
      ]
    )
    let definition = imapDefinition(username: "reader")
    let client = SystemIMAPMailboxClient(
      streamTaskFactory: TranscriptIMAPStreamTaskFactory(tasks: [firstTask, retryTask])
    )
    let authorization = DeviceLocalGenericMailAuthorization(
      credential: "secret",
      definition: definition
    )
    let message = imapMessage(uid: 7)

    do {
      try await client.perform(
        .archive,
        message: message,
        targetMailbox: "Archive",
        authorization: authorization
      )
      XCTFail("Expected the first deletion attempt to disconnect")
    } catch is URLError {
    }
    try await client.perform(
      .archive,
      message: message,
      targetMailbox: "Archive",
      authorization: authorization
    )

    XCTAssertTrue(firstTask.writes.contains("A7 UID COPY 7 \"Archive\"\r\n"))
    XCTAssertFalse(retryTask.writes.contains { $0.contains("UID COPY") })
    XCTAssertTrue(retryTask.writes.contains("A8 UID EXPUNGE 7\r\n"))
  }

  func testSystemSMTPClientSubmitsDotStuffedMessage() async throws {
    let task = TranscriptIMAPStreamTask(
      responses: [
        "220 ready\r\n",
        "250 AUTH PLAIN\r\n",
        "235 authenticated\r\n",
        "250 sender accepted\r\n",
        "250 recipient accepted\r\n",
        "354 send data\r\n",
        "250 queued\r\n",
      ]
    )
    let definition = imapDefinition(username: "sender")
    let client = SystemSMTPMailClient(
      streamTaskFactory: TranscriptIMAPStreamTaskFactory(tasks: [task])
    )

    try await client.send(
      Data("Subject: Dot\r\n\r\n.first\r\nsecond".utf8),
      envelopeFrom: definition.emailAddress,
      envelopeRecipients: ["reader@example.com"],
      authorization: DeviceLocalGenericMailAuthorization(
        credential: "secret",
        definition: definition
      )
    )

    XCTAssertTrue(task.writes.contains("MAIL FROM:<sender@example.com>\r\n"))
    XCTAssertTrue(task.writes.contains("RCPT TO:<reader@example.com>\r\n"))
    XCTAssertTrue(task.writes.contains("Subject: Dot\r\n\r\n..first\r\nsecond\r\n.\r\n"))
  }

  func testSystemSMTPClientReportsUncertainDeliveryAfterDataDisconnect() async throws {
    let task = TranscriptIMAPStreamTask(
      responses: [
        .success("220 ready\r\n"),
        .success("250 AUTH PLAIN\r\n"),
        .success("235 authenticated\r\n"),
        .success("250 sender accepted\r\n"),
        .success("250 recipient accepted\r\n"),
        .success("354 send data\r\n"),
        .failure(URLError(.networkConnectionLost)),
      ]
    )
    let definition = imapDefinition(username: "sender")
    let client = SystemSMTPMailClient(
      streamTaskFactory: TranscriptIMAPStreamTaskFactory(tasks: [task])
    )

    do {
      try await client.send(
        Data("Subject: Accepted?\r\n\r\nbody".utf8),
        envelopeFrom: definition.emailAddress,
        envelopeRecipients: ["reader@example.com"],
        authorization: DeviceLocalGenericMailAuthorization(
          credential: "secret",
          definition: definition
        )
      )
      XCTFail("Expected an uncertain delivery result")
    } catch {
      XCTAssertEqual(error as? SMTPMailError, .deliveryUncertainAfterSubmission)
    }
  }

  func testSystemSMTPClientCompletesXOAUTH2ErrorContinuation() async throws {
    let task = TranscriptIMAPStreamTask(
      responses: [
        "220 ready\r\n",
        "250 AUTH XOAUTH2\r\n",
        "334 eyJzdGF0dXMiOiI0MDEifQ==\r\n",
        "535 authentication rejected\r\n",
      ]
    )
    let definition = imapDefinition(username: "sender", authorizationMethod: .oauth)
    let client = SystemSMTPMailClient(
      streamTaskFactory: TranscriptIMAPStreamTaskFactory(tasks: [task])
    )

    do {
      try await client.send(
        Data("Subject: Auth\r\n\r\nbody".utf8),
        envelopeFrom: definition.emailAddress,
        envelopeRecipients: ["reader@example.com"],
        authorization: DeviceLocalGenericMailAuthorization(
          credential: "expired-token",
          definition: definition
        )
      )
      XCTFail("Expected authentication rejection")
    } catch {
      XCTAssertEqual(error as? SMTPMailError, .responseCode(535))
    }

    XCTAssertTrue(task.writes.contains("\r\n"))
  }

  func testSystemIMAPClientUsesLongLivedReadForIDLEChanges() async throws {
    let task = TranscriptIMAPStreamTask(
      responses: [
        "* OK ready\r\n",
        "A1 OK authenticated\r\n",
        "* CAPABILITY IMAP4rev1 IDLE\r\nA2 OK capable\r\n",
        "* OK [UIDVALIDITY 1] selected\r\nA3 OK selected\r\n",
        "+ idling\r\n",
        "* 1 EXISTS\r\n",
        "A4 OK IDLE terminated\r\n",
      ]
    )
    let definition = imapDefinition(username: "idle")
    let client = SystemIMAPMailboxClient(
      streamTaskFactory: TranscriptIMAPStreamTaskFactory(tasks: [task])
    )

    try await client.waitForChange(
      in: "INBOX",
      authorization: DeviceLocalGenericMailAuthorization(
        credential: "secret",
        definition: definition
      )
    )

    XCTAssertEqual(task.readTimeouts, [29 * 60])
    XCTAssertTrue(task.writes.contains("A4 IDLE\r\n"))
    XCTAssertTrue(task.writes.contains("DONE\r\n"))
  }

  func testSystemIMAPClientReportsUnknownAppendAfterLiteralDisconnect() async throws {
    let task = TranscriptIMAPStreamTask(
      responses: [
        .success("* OK ready\r\n"),
        .success("A1 OK authenticated\r\n"),
        .success("+ continue\r\n"),
        .failure(URLError(.networkConnectionLost)),
      ]
    )
    let definition = imapDefinition(username: "sender")
    let client = SystemIMAPMailboxClient(
      streamTaskFactory: TranscriptIMAPStreamTaskFactory(tasks: [task])
    )

    do {
      try await client.appendMessage(
        Data("Subject: Saved?\r\n\r\nbody".utf8),
        to: "Sent",
        flags: ["\\Seen"],
        authorization: DeviceLocalGenericMailAuthorization(
          credential: "secret",
          definition: definition
        )
      )
      XCTFail("Expected an unknown APPEND outcome")
    } catch {
      XCTAssertEqual(error as? IMAPMailboxError, .appendOutcomeUnknown)
    }

    XCTAssertTrue(task.writes.contains { $0.hasPrefix("A2 APPEND \"Sent\"") })
    XCTAssertTrue(task.writes.contains("Subject: Saved?\r\n\r\nbody\r\n"))
  }

  func testSystemIMAPClientReportsUnknownAppendWhenLiteralWriteFails() async throws {
    let task = TranscriptIMAPStreamTask(
      responses: [
        "* OK ready\r\n",
        "A1 OK authenticated\r\n",
        "+ continue\r\n",
      ]
    )
    task.writeFailureAtCall = 3
    let definition = imapDefinition(username: "sender")
    let client = SystemIMAPMailboxClient(
      streamTaskFactory: TranscriptIMAPStreamTaskFactory(tasks: [task])
    )

    do {
      try await client.appendMessage(
        Data("Subject: Saved?\r\n\r\nbody".utf8),
        to: "Sent",
        flags: ["\\Seen"],
        authorization: DeviceLocalGenericMailAuthorization(
          credential: "secret",
          definition: definition
        )
      )
      XCTFail("Expected an unknown APPEND outcome")
    } catch {
      XCTAssertEqual(error as? IMAPMailboxError, .appendOutcomeUnknown)
    }
  }

  private func authorizedStore(
    _ definition: GenericMailConnectionDefinition
  ) -> RecordingIMAPAuthorizationStore {
    let store = RecordingIMAPAuthorizationStore()
    store.save(
      DeviceLocalGenericMailAuthorization(credential: "secret", definition: definition),
      productAccountId: ProductAccountId(session.productAccountId)
    )
    return store
  }

  private func makeAdapter(
    authorizationStore: RecordingIMAPAuthorizationStore,
    cache: GmailMessageBodyCaching = RecordingIMAPBodyCache(),
    client: RecordingIMAPClient,
    definitions: [GenericMailConnectionDefinition],
    keyStore: ProductSyncKeyMaterialPersisting = InMemoryProductSyncKeyMaterialStore(),
    store: IMAPMessageMetadataPersisting? = nil,
    pendingStore: PendingProviderActionPersisting = RecordingPendingProviderActionStore(),
    smtpClient: SMTPMailClient = RecordingSMTPMailClient()
  ) throws -> IMAPMailboxConnectionAdapter {
    let metadataStore = try store ?? SwiftDataIMAPMessageMetadataStore.inMemory()
    return IMAPMailboxConnectionAdapter(
      authorizationStore: authorizationStore,
      cache: cache,
      client: client,
      definitionSyncService: RecordingIMAPDefinitionSyncService(
        definitions: definitions
      ),
      keyMaterialStore: keyStore,
      metadataStore: metadataStore,
      outboxService: OutboxDeliveryService(store: RecordingIMAPOutboxStore()),
      pendingActionService: PendingProviderActionService(
        retryDelayNanoseconds: { _ in 0 },
        store: pendingStore
      ),
      smtpClient: smtpClient,
      syncGate: MailboxConnectionSyncGate()
    )
  }
}

private func imapDefinition(
  username: String,
  authorizationMethod: MailAuthorizationMethod = .password,
  imapCapabilities: Set<String>? = nil,
  roleMappings: [CanonicalMailboxRole: String] = [
    .archive: "Archive",
    .drafts: "Drafts",
    .sent: "Sent",
    .spam: "Spam",
    .trash: "Trash",
  ]
) -> GenericMailConnectionDefinition {
  GenericMailConnectionDefinition(
    authorizationMethod: authorizationMethod,
    emailAddress: "\(username)@example.com",
    imapCapabilities: imapCapabilities,
    incomingEndpoint: GenericMailEndpoint(
      mailProtocol: .imap,
      hostname: "imap.\(username).example.com",
      port: 993,
      security: .implicitTLS
    ),
    outgoingEndpoint: GenericMailEndpoint(
      mailProtocol: .smtp,
      hostname: "smtp.\(username).example.com",
      port: 465,
      security: .implicitTLS
    ),
    roleMappings: roleMappings,
    username: username
  )
}

private func imapMessage(
  mailbox: String = "INBOX",
  uid: Int64,
  uidValidity: Int64 = 1,
  flags: [String] = [],
  inReplyTo: String? = nil,
  references: [String] = [],
  rfcMessageId: String? = nil,
  providerEmailId: String? = nil,
  providerThreadId: String? = nil,
  subject: String = "Subject"
) -> IMAPProviderMessage {
  IMAPProviderMessage(
    categoryId: nil,
    cc: nil,
    flags: flags,
    from: "Sender <sender@example.com>",
    inReplyTo: inReplyTo,
    internalDateMilliseconds: 1_781_200_000_000 + uid,
    mailbox: mailbox,
    providerEmailId: providerEmailId,
    providerThreadId: providerThreadId,
    references: references,
    replyTo: nil,
    rfcMessageId: rfcMessageId ?? "<message-\(uid)@example.com>",
    snippet: "Snippet",
    subject: subject,
    to: "reader@example.com",
    uid: uid,
    uidValidity: uidValidity
  )
}

private final class RecordingIMAPAuthorizationStore: GenericMailAuthorizationPersisting {
  private var authorizations: [String: DeviceLocalGenericMailAuthorization] = [:]

  func clearAll(productAccountId: ProductAccountId) throws {
    authorizations = authorizations.filter { !$0.key.hasPrefix("\(productAccountId.rawValue):") }
  }

  func load(
    productAccountId: ProductAccountId,
    emailAddress: String
  ) throws -> DeviceLocalGenericMailAuthorization? {
    authorizations.values.first { $0.definition.emailAddress == emailAddress }
  }

  func load(
    productAccountId: ProductAccountId,
    connectionId: MailboxConnectionId
  ) throws -> DeviceLocalGenericMailAuthorization? {
    authorizations[key(productAccountId: productAccountId, connectionId: connectionId)]
  }

  func remove(
    productAccountId: ProductAccountId,
    connectionId: MailboxConnectionId
  ) throws {
    authorizations[key(productAccountId: productAccountId, connectionId: connectionId)] = nil
  }

  func save(
    _ authorization: DeviceLocalGenericMailAuthorization,
    productAccountId: ProductAccountId
  ) {
    authorizations[
      key(productAccountId: productAccountId, connectionId: authorization.definition.connectionId)
    ] = authorization
  }

  private func key(
    productAccountId: ProductAccountId,
    connectionId: MailboxConnectionId
  ) -> String {
    "\(productAccountId.rawValue):\(connectionId.rawValue)"
  }
}

private final class RecordingIMAPDefinitionSyncService: MailboxConnectionDefinitionSyncing {
  private var snapshot: MailboxConnectionSyncSnapshot

  init(definitions: [GenericMailConnectionDefinition]) {
    snapshot = MailboxConnectionSyncSnapshot(
      connections: definitions.enumerated().map {
        $0.element.synchronizedDefinition(connectedAt: Int64($0.offset + 1))
      },
      defaultSendingConnectionId: nil,
      removedConnectionIds: [],
      updatedAt: 10
    )
  }

  func loadSnapshot(
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    snapshot
  }

  func reconcileConnections(
    _ connections: [MailboxConnectionDefinition],
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    snapshot = MailboxConnectionSyncSnapshot(
      connections: connections,
      defaultSendingConnectionId: snapshot.defaultSendingConnectionId,
      removedConnectionIds: snapshot.removedConnectionIds,
      updatedAt: snapshot.updatedAt
    )
    return snapshot
  }

  func removeConnection(
    _ connectionId: MailboxConnectionId,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    snapshot = MailboxConnectionSyncSnapshot(
      connections: snapshot.connections.filter { $0.id != connectionId },
      defaultSendingConnectionId: snapshot.defaultSendingConnectionId,
      removedConnectionIds: snapshot.removedConnectionIds + [connectionId],
      updatedAt: snapshot.updatedAt
    )
    return snapshot
  }

  func saveConnection(
    _ connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    try await saveDefinition(connection.definition, session: session)
  }

  func saveDefinition(
    _ definition: MailboxConnectionDefinition,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    snapshot = MailboxConnectionSyncSnapshot(
      connections: snapshot.connections.filter { $0.id != definition.id } + [definition],
      defaultSendingConnectionId: snapshot.defaultSendingConnectionId,
      removedConnectionIds: snapshot.removedConnectionIds.filter { $0 != definition.id },
      updatedAt: snapshot.updatedAt
    )
    return snapshot
  }

  func setDefaultSendingConnection(
    _ connectionId: MailboxConnectionId?,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    snapshot = MailboxConnectionSyncSnapshot(
      connections: snapshot.connections,
      defaultSendingConnectionId: connectionId,
      removedConnectionIds: snapshot.removedConnectionIds,
      updatedAt: snapshot.updatedAt
    )
    return snapshot
  }
}

private final class RecordingIMAPClient: IMAPMailboxClient {
  struct AppendedMessage {
    let flags: [String]
    let mailbox: String
    let message: Data
  }

  struct PerformedAction {
    let action: ProviderMailAction
    let targetMailbox: String?
    let uid: Int64
  }

  private(set) var appendedMessages: [AppendedMessage] = []
  var appendError: Error?
  var bodyByUID: [Int64: String] = [:]
  private(set) var bodyRequestCount = 0
  var failOnMetadataRequest: Int?
  var failsAppend = false
  var mailboxesByUsername: [String: [IMAPMailboxDescriptor]] = [:]
  var messagesByUsername: [String: [IMAPProviderMessage]] = [:]
  var messagesByUsernameAndMailbox: [String: [String: [IMAPProviderMessage]]] = [:]
  private(set) var metadataRequestCount = 0
  private(set) var performedActions: [PerformedAction] = []
  var supportsIdleResult = false
  private(set) var supportsIdleRequestCount = 0
  var uidValidityByUsername: [String: Int64] = [:]
  private(set) var waitedMailboxes: [String] = []

  func appendMessage(
    _ message: Data,
    to mailbox: String,
    flags: [String],
    authorization _: DeviceLocalGenericMailAuthorization
  ) async throws {
    if let appendError { throw appendError }
    if failsAppend { throw IMAPMailboxError.invalidProviderResponse }
    appendedMessages.append(
      AppendedMessage(flags: flags, mailbox: mailbox, message: message)
    )
  }

  func listMailboxes(
    authorization: DeviceLocalGenericMailAuthorization
  ) async throws -> [IMAPMailboxDescriptor] {
    mailboxesByUsername[authorization.definition.username]
      ?? [IMAPMailboxDescriptor(displayName: "Inbox", name: "INBOX")]
  }

  func loadMetadataPage(
    mailbox: IMAPMailboxDescriptor,
    beforeUID: Int64?,
    limit: Int,
    authorization: DeviceLocalGenericMailAuthorization
  ) async throws -> IMAPMetadataPage {
    metadataRequestCount += 1
    if metadataRequestCount == failOnMetadataRequest {
      throw CancellationError()
    }
    let username = authorization.definition.username
    let messages =
      messagesByUsernameAndMailbox[username]?[mailbox.name]
      ?? messagesByUsername[username, default: []].filter { $0.mailbox == mailbox.name }
    let eligible = messages.filter { message in
      beforeUID.map { message.uid < $0 } ?? true
    }
    .sorted { $0.uid < $1.uid }
    let pageMessages = Array(eligible.suffix(limit))
    let next = eligible.count > pageMessages.count ? pageMessages.first?.uid : nil
    return IMAPMetadataPage(
      messages: pageMessages,
      nextOlderUID: next,
      uidValidity: uidValidityByUsername[username] ?? pageMessages.first?.uidValidity ?? 1
    )
  }

  func loadTextBody(
    message: IMAPProviderMessage,
    authorization _: DeviceLocalGenericMailAuthorization
  ) async throws -> String {
    bodyRequestCount += 1
    return bodyByUID[message.uid] ?? "Body \(message.uid)"
  }

  func perform(
    _ action: ProviderMailAction,
    message: IMAPProviderMessage,
    targetMailbox: String?,
    authorization _: DeviceLocalGenericMailAuthorization
  ) async throws {
    performedActions.append(
      PerformedAction(action: action, targetMailbox: targetMailbox, uid: message.uid)
    )
  }

  func supportsIdle(
    authorization _: DeviceLocalGenericMailAuthorization
  ) async throws -> Bool {
    supportsIdleRequestCount += 1
    return supportsIdleResult
  }

  func waitForChange(
    in mailbox: String,
    authorization _: DeviceLocalGenericMailAuthorization
  ) async throws {
    waitedMailboxes.append(mailbox)
  }
}

private final class RecordingSMTPMailClient: SMTPMailClient {
  private(set) var envelopeRecipients: [[String]] = []
  private(set) var sentMessages: [Data] = []

  func send(
    _ message: Data,
    envelopeFrom _: String,
    envelopeRecipients: [String],
    authorization _: DeviceLocalGenericMailAuthorization
  ) async throws {
    sentMessages.append(message)
    self.envelopeRecipients.append(envelopeRecipients)
  }
}

private final class RecordingPendingProviderActionStore: PendingProviderActionPersisting {
  private var actionsByProductAccountId: [String: [PendingProviderAction]] = [:]

  func load(productAccountId: String) throws -> [PendingProviderAction] {
    actionsByProductAccountId[productAccountId, default: []]
  }

  func save(
    _ actions: [PendingProviderAction],
    productAccountId: String
  ) throws {
    actionsByProductAccountId[productAccountId] = actions
  }
}

private final class RecordingIMAPOutboxStore: OutboxDeliveryPersisting {
  private var attemptsByProductAccountId: [String: [OutgoingDeliveryAttempt]] = [:]

  func load(productAccountId: String) throws -> [OutgoingDeliveryAttempt] {
    attemptsByProductAccountId[productAccountId, default: []]
  }

  func save(
    _ attempts: [OutgoingDeliveryAttempt],
    productAccountId: String
  ) throws {
    attemptsByProductAccountId[productAccountId] = attempts
  }
}

private final class RecordingIMAPBodyCache: GmailMessageBodyCaching {
  private var payloads: [String: ProductSyncEncryptedPayload] = [:]

  func clearMessageBodies(productAccountId _: String) throws {
    payloads.removeAll()
  }

  func clearMessageBodies(
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws {
    payloads.removeAll()
  }

  func loadMessageBody(
    productAccountId _: String,
    stableProviderMessageId: String
  ) throws -> ProductSyncEncryptedPayload? {
    payloads[stableProviderMessageId]
  }

  func removeMessageBody(
    productAccountId _: String,
    stableProviderMessageId: String
  ) throws {
    payloads[stableProviderMessageId] = nil
  }

  func saveMessageBody(
    _ payload: ProductSyncEncryptedPayload,
    productAccountId _: String,
    stableProviderMessageId: String
  ) throws {
    payloads[stableProviderMessageId] = payload
  }

  func reconcileSelection(
    productAccountId _: String,
    providerAccountIdentifier _: String,
    protectedMessageIds _: Set<String>,
    pinnedMessageIds _: Set<String>
  ) throws {}

  func recordMessageBodyAccess(
    productAccountId _: String,
    stableProviderMessageId _: String,
    accessedAt _: Date
  ) throws {}
}

private final class TranscriptIMAPStreamTaskFactory: GenericMailStreamTaskCreating {
  private var tasks: [TranscriptIMAPStreamTask]

  init(tasks: [TranscriptIMAPStreamTask]) {
    self.tasks = tasks
  }

  func makeStreamTask(
    hostname _: String,
    port _: Int,
    minimumTransportVersion _: MailTransportVersion
  ) -> GenericMailStreamTasking {
    tasks.removeFirst()
  }
}

private final class TranscriptIMAPStreamTask: GenericMailStreamTasking {
  private var responses: [Result<Data, Error>]
  private(set) var readTimeouts: [TimeInterval] = []
  private(set) var writes: [String] = []
  var writeFailureAtCall: Int?

  init(responses: [String]) {
    self.responses = responses.map { .success(Data($0.utf8)) }
  }

  init(responses: [Result<String, Error>]) {
    self.responses = responses.map { $0.map { Data($0.utf8) } }
  }

  init(responsesData: [Data]) {
    responses = responsesData.map(Result.success)
  }

  func close() {}

  func read() async throws -> String {
    guard !responses.isEmpty else { throw IMAPMailboxError.invalidProviderResponse }
    let data = try responses.removeFirst().get()
    guard let response = String(data: data, encoding: .utf8) else {
      throw IMAPMailboxError.invalidProviderResponse
    }
    return response
  }

  func readData() async throws -> Data {
    guard !responses.isEmpty else { throw IMAPMailboxError.invalidProviderResponse }
    return try responses.removeFirst().get()
  }

  func readData(timeout: TimeInterval) async throws -> Data {
    readTimeouts.append(timeout)
    return try await readData()
  }

  func resume() {}

  func startSecureConnection() {}

  func write(_ value: String) async throws {
    writes.append(value)
    if writes.count == writeFailureAtCall {
      throw URLError(.networkConnectionLost)
    }
  }
}

extension Collection {
  fileprivate func asyncMap<T>(
    _ transform: (Element) async throws -> T
  ) async rethrows -> [T] {
    var results: [T] = []
    for element in self {
      results.append(try await transform(element))
    }
    return results
  }
}
