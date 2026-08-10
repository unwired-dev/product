import Foundation
import Testing

@testable import unwired_mail

@Suite
struct SwiftMailGenericMailClientTests {
  @Test
  func testConnectionVerifierUsesOneQualifiedEngineConnection() async throws {
    let definition = makeDefinition(authorizationMethod: .oauth)
    let session = RecordingBridgeMailSession()
    let engine = RecordingBridgeMailEngine(
      session: session,
      snapshot: MailEngineConnectionSnapshot(
        capabilities: [.specialUse],
        mailboxes: [
          MailEngineMailbox(
            identity: MailEngineMailboxIdentity("Archive"),
            specialUses: [.archive]
          ),
          MailEngineMailbox(
            identity: MailEngineMailboxIdentity("&ZeVnLIqe-"),
            specialUses: [.sent]
          ),
          MailEngineMailbox(
            identity: MailEngineMailboxIdentity("Other Sent"),
            specialUses: [.sent]
          ),
          MailEngineMailbox(
            identity: MailEngineMailboxIdentity("Unavailable"),
            isSelectable: false,
            specialUses: [.trash]
          ),
        ],
        minimumTLSVersions: [.imap: .tls12, .smtp: .tls13]
      )
    )

    let verification = try await SwiftMailGenericMailConnectionVerifier(engine: engine).verify(
      definition: definition,
      credential: "oauth-token"
    )
    let configurations = await engine.recordedConfigurations()

    #expect(configurations.count == 1)
    #expect(
      configurations.first?.authorization
        == .xoauth2(username: definition.username, accessToken: "oauth-token")
    )
    #expect(configurations.first?.connectionID == definition.connectionId.rawValue)
    #expect(configurations.first?.imapEndpoint.hostname == "imap.example.com")
    #expect(configurations.first?.imapEndpoint.transportMode == .implicitTLS)
    #expect(configurations.first?.smtpEndpoint.hostname == "smtp.example.com")
    #expect(configurations.first?.smtpEndpoint.transportMode == .startTLS)
    #expect(configurations.first?.minimumTLSVersion == .tls12)
    #expect(verification.discoveredRoleMappings == [.archive: "Archive"])
    #expect(verification.canonicalMailboxName(matching: "日本語") == "&ZeVnLIqe-")
    #expect(verification.canonicalMailboxName(matching: "Other Sent") == "Other Sent")
    #expect(verification.canonicalMailboxName(matching: "Unavailable") == nil)
    #expect(await session.recordedCloseCount() == 1)
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testInitialMailboxLoaderMapsNewestMetadataAndSkipsUnselectableMailboxes() async throws {
    let definition = makeDefinition()
    let inbox = MailEngineMailboxIdentity("INBOX")
    let unavailable = MailEngineMailboxIdentity("Unavailable")
    let page = MailEngineMetadataPage(
      messages: [
        MailEngineMessageMetadata(
          carbonCopyRecipients: ["Copy <copy@example.com>"],
          flags: ["\\Seen", "\\Flagged"],
          from: "Sender <sender@example.com>",
          identity: MailEngineMessageIdentity(
            connectionID: definition.connectionId.rawValue,
            mailbox: inbox,
            uid: 51,
            uidValidity: 7
          ),
          inReplyTo: "<root@example.com>",
          internalDate: Date(timeIntervalSince1970: 1_000),
          references: ["<root@example.com>"],
          replyTo: "Replies <reply@example.com>",
          rfcMessageID: "<message@example.com>",
          subject: "Newest message",
          recipients: ["Reader <reader@example.com>"]
        )
      ],
      nextOlderUID: 51,
      uidValidity: 7
    )
    let session = RecordingBridgeMailSession(pages: [inbox: page])
    let engine = RecordingBridgeMailEngine(
      session: session,
      snapshot: MailEngineConnectionSnapshot(
        capabilities: [],
        mailboxes: [
          MailEngineMailbox(identity: inbox, specialUses: []),
          MailEngineMailbox(identity: unavailable, isSelectable: false, specialUses: []),
        ],
        minimumTLSVersions: [.imap: .tls12, .smtp: .tls12]
      )
    )
    let authorization = DeviceLocalGenericMailAuthorization(
      credential: "secret",
      definition: definition
    )

    let pages = try await SwiftMailInitialMailboxLoader(engine: engine).loadInitialMailbox(
      authorization: authorization,
      limit: 50
    )
    let message = try #require(pages.first?.page.messages.first)

    #expect(pages.map(\.descriptor.name) == ["INBOX"])
    #expect(pages.first?.page.nextOlderUID == 51)
    #expect(message.cc == "Copy <copy@example.com>")
    #expect(message.flags == ["\\Flagged", "\\Seen"])
    #expect(message.from == "Sender <sender@example.com>")
    #expect(message.inReplyTo == "<root@example.com>")
    #expect(message.internalDateMilliseconds == 1_000_000)
    #expect(message.references == ["<root@example.com>"])
    #expect(message.replyTo == "Replies <reply@example.com>")
    #expect(message.rfcMessageId == "<message@example.com>")
    #expect(message.subject == "Newest message")
    #expect(message.to == "Reader <reader@example.com>")
    #expect(message.uid == 51)
    #expect(message.uidValidity == 7)
    #expect(await session.recordedRequests() == [MetadataRequest(mailbox: inbox, limit: 50)])
    #expect(await session.recordedCloseCount() == 1)
  }

  private func makeDefinition(
    authorizationMethod: MailAuthorizationMethod = .password
  ) -> GenericMailConnectionDefinition {
    GenericMailConnectionDefinition(
      authorizationMethod: authorizationMethod,
      emailAddress: "reader@example.com",
      incomingEndpoint: GenericMailEndpoint(
        mailProtocol: .imap,
        hostname: "imap.example.com",
        port: 993,
        security: .implicitTLS
      ),
      outgoingEndpoint: GenericMailEndpoint(
        mailProtocol: .smtp,
        hostname: "smtp.example.com",
        port: 587,
        security: .startTLS
      ),
      roleMappings: [:],
      username: "reader@example.com"
    )
  }
}

private struct MetadataRequest: Equatable {
  let mailbox: MailEngineMailboxIdentity
  let limit: Int
}

private actor RecordingBridgeMailEngine: MailEngine {
  private var configurations: [MailEngineConfiguration] = []
  private let session: RecordingBridgeMailSession
  private let snapshot: MailEngineConnectionSnapshot

  init(
    session: RecordingBridgeMailSession,
    snapshot: MailEngineConnectionSnapshot
  ) {
    self.session = session
    self.snapshot = snapshot
  }

  func connect(
    configuration: MailEngineConfiguration,
    logger _: any MailEngineLogging
  ) async throws -> (snapshot: MailEngineConnectionSnapshot, session: any MailEngineSession) {
    configurations.append(configuration)
    return (snapshot, session)
  }

  func recordedConfigurations() -> [MailEngineConfiguration] { configurations }
}

private actor RecordingBridgeMailSession: MailEngineSession {
  private var closeCount = 0
  private let pages: [MailEngineMailboxIdentity: MailEngineMetadataPage]
  private var requests: [MetadataRequest] = []

  init(pages: [MailEngineMailboxIdentity: MailEngineMetadataPage] = [:]) {
    self.pages = pages
  }

  func appendToSent(
    _: Data,
    mailbox _: MailEngineMailboxIdentity
  ) async throws -> MailEngineMessageIdentity {
    throw MailEngineError.operationUnsupported
  }

  func close() async { closeCount += 1 }

  func copy(
    messages _: [MailEngineMessageIdentity],
    to _: MailEngineMailboxIdentity
  ) async throws -> MailEngineUIDMapping {
    throw MailEngineError.operationUnsupported
  }

  func fetchBodyParts(
    _: Set<MailEngineBodyPartSelector>,
    for _: MailEngineMessageIdentity
  ) async throws -> [MailEngineBodyPart] {
    throw MailEngineError.operationUnsupported
  }

  func idle(
    mailbox _: MailEngineMailboxIdentity,
    onEvent _: @escaping @Sendable (MailEngineIdleEvent) async -> Void
  ) async throws {
    throw MailEngineError.operationUnsupported
  }

  func loadMetadataPage(
    mailbox: MailEngineMailboxIdentity,
    beforeUID _: Int64?,
    limit: Int
  ) async throws -> MailEngineMetadataPage {
    requests.append(MetadataRequest(mailbox: mailbox, limit: limit))
    guard let page = pages[mailbox] else { throw MailEngineError.connectionClosed }
    return page
  }

  func move(
    messages _: [MailEngineMessageIdentity],
    to _: MailEngineMailboxIdentity
  ) async throws -> MailEngineUIDMapping {
    throw MailEngineError.operationUnsupported
  }

  func submit(
    envelope _: MailEngineEnvelope,
    rawMessage _: Data
  ) async throws -> MailEngineSMTPOutcome {
    throw MailEngineError.operationUnsupported
  }

  func recordedCloseCount() -> Int { closeCount }

  func recordedRequests() -> [MetadataRequest] { requests }
}
