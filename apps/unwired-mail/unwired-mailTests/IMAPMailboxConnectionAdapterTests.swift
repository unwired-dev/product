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
    XCTAssertEqual(connections[0].capabilities, .imapRead)
    XCTAssertEqual(connections[0].id, definition.connectionId)
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

    XCTAssertFalse(refreshed.historicalMetadataBackfillIsComplete)
    XCTAssertEqual(refreshed.messages.count, 50)
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

  func testCompletedBackfillRemovesAnExpungedOlderMessageOnRefresh() async throws {
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
    client.messagesByUsername[definition.username]?.removeAll { $0.uid == 1 }

    let refreshed = try await adapter.syncInbox(connection: connection, session: session)

    XCTAssertEqual(refreshed.messages.count, 74)
    XCTAssertFalse(refreshed.messages.contains { $0.subject == "Message 1" })
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
    XCTAssertEqual(persisted.messages.count, 50)

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
    store: IMAPMessageMetadataPersisting? = nil
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
      syncGate: MailboxConnectionSyncGate()
    )
  }
}

private func imapDefinition(
  username: String,
  roleMappings: [CanonicalMailboxRole: String] = [
    .archive: "Archive",
    .drafts: "Drafts",
    .sent: "Sent",
    .spam: "Spam",
    .trash: "Trash",
  ]
) -> GenericMailConnectionDefinition {
  GenericMailConnectionDefinition(
    authorizationMethod: .password,
    emailAddress: "\(username)@example.com",
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
    flags: [],
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
  var bodyByUID: [Int64: String] = [:]
  private(set) var bodyRequestCount = 0
  var failOnMetadataRequest: Int?
  var mailboxesByUsername: [String: [IMAPMailboxDescriptor]] = [:]
  var messagesByUsername: [String: [IMAPProviderMessage]] = [:]
  var messagesByUsernameAndMailbox: [String: [String: [IMAPProviderMessage]]] = [:]
  private(set) var metadataRequestCount = 0
  var uidValidityByUsername: [String: Int64] = [:]

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
  private var responses: [Data]
  private(set) var writes: [String] = []

  init(responses: [String]) {
    self.responses = responses.map { Data($0.utf8) }
  }

  init(responsesData: [Data]) {
    responses = responsesData
  }

  func close() {}

  func read() async throws -> String {
    guard !responses.isEmpty else { throw IMAPMailboxError.invalidProviderResponse }
    guard let response = String(data: responses.removeFirst(), encoding: .utf8) else {
      throw IMAPMailboxError.invalidProviderResponse
    }
    return response
  }

  func readData() async throws -> Data {
    guard !responses.isEmpty else { throw IMAPMailboxError.invalidProviderResponse }
    return responses.removeFirst()
  }

  func resume() {}

  func startSecureConnection() {}

  func write(_ value: String) async throws {
    writes.append(value)
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
