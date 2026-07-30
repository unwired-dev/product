import Foundation
import XCTest

@testable import unwired_mail

// swiftlint:disable file_length type_body_length

final class MailEngineQualificationTests: XCTestCase {
  func testSetupTransportAuthenticationAndCapabilitiesContract() async throws {
    try await makeContract().verifySetupTransportAuthenticationAndCapabilities()
  }

  func testRejectsInsecureTransportAndInvalidServerIdentityContract() async throws {
    try await makeContract().verifyTransportAndServerIdentityFailures()
  }

  func testUIDAndUIDValidityMappingContract() async throws {
    try await makeContract().verifyUIDMappings()
  }

  func testMetadataPagingAndSelectedBodyPartsContract() async throws {
    try await makeContract().verifyMetadataAndBodyParts()
  }

  func testIDLERecoveryCancellationAndConnectionIsolationContract() async throws {
    try await makeContract().verifyIDLEAndConnectionIsolation()
  }

  func testSMTPOutcomeAndSentAppendRecoveryContract() async throws {
    try await makeContract().verifySMTPAndSentAppend()
  }

  func testContentBearingProtocolTracesCannotReachProductionLogSinkContract() async throws {
    try await makeContract().verifyProtocolTracePrivacy()
  }

  func testClosedSessionRejectsFurtherWorkContract() async throws {
    try await makeContract().verifyConnectionLifecycle()
  }

  private func makeContract() -> MailEngineQualificationContract {
    MailEngineQualificationContract(factory: ScriptedMailEngineQualificationFactory())
  }
}

/// Candidate adapters qualify by providing this factory against the same deterministic fixtures.
protocol MailEngineQualificationCandidateFactory: Sendable {
  func configuration(
    fixture: MailEngineQualificationFixture,
    authorization: MailEngineAuthorization,
    connectionID: String,
    imapTransportMode: MailEngineTransportMode,
    smtpTransportMode: MailEngineTransportMode
  ) -> MailEngineConfiguration
  func events() async -> [MailEngineQualificationEvent]
  func capturedCandidateLogOutput() async -> Data
  func makeEngine(
    fixture: MailEngineQualificationFixture
  ) -> any MailEngine
  func waitForBodyFetchStarts(_ count: Int, timeout: Duration) async throws
  func waitForConnectionSetupQuiescence(
    connectionID: String,
    timeout: Duration
  ) async throws
  func waitForClosedSessionQuiescence(
    connectionID: String,
    timeout: Duration
  ) async throws
  func waitForIdleLateCallbackAttempt(
    connectionID: String,
    timeout: Duration
  ) async throws
  func waitForIdleStarts(_ count: Int, timeout: Duration) async throws
  func waitForSubmissionEnvelopeAccepted(
    connectionID: String,
    timeout: Duration
  ) async throws
  func waitForSubmissionStarts(_ count: Int, timeout: Duration) async throws
  func waitForSubmissionContentStarts(
    _ count: Int,
    connectionID: String,
    timeout: Duration
  ) async throws
  func waitForSubmissionTransportTermination(
    connectionID: String,
    timeout: Duration
  ) async throws
}

enum MailEngineQualificationFixture: Sendable {
  case bodyFetchUntilCancelled
  case connectionFailure(service: MailEngineService, error: MailEngineError)
  case copyOutcomeUnknown
  case copyPermanentlyRejected
  case copyRetryablyRejected
  case emptyUIDMapping
  case idleDisconnectThenRecover(
    maximumReconnectTLSVersion: MailEngineTLSVersion?,
    requiresXOAUTH2Challenge: Bool
  )
  case idleDisconnectThenUnsecuredSTARTTLS
  case idleDisconnectThenRejectAuthentication(requiresXOAUTH2Challenge: Bool)
  case idleDisconnectThenRejectRecovery(error: MailEngineError)
  case invalidIdleChangedUID(uid: Int64)
  case invalidIdleResetUIDValidity(uidValidity: Int64)
  case idleUntilCancelled
  case inFlightOperationsUntilClosed
  case mismatchedMetadataUIDValidity
  case invalidMetadataMessageUIDValidity(uidValidity: Int64)
  case invalidMetadataNextOlderUID(uid: Int64)
  case invalidMetadataPageUIDValidity(uidValidity: Int64)
  case invalidMetadataUID(uid: Int64)
  case malformedCopyUIDMapping
  case mismatchedUIDMappingCardinality
  case repeatedDestinationUIDMapping
  case maximumTLS(service: MailEngineService, version: MailEngineTLSVersion)
  case overlappingBodyResults
  case overlappingCopyResults
  case overlappingConnectionSetup
  case overlappingMoveResults
  case overlappingSentAppend(uid: Int64, uidValidity: Int64)
  case overlappingSMTP(serverMessageID: String)
  case moveOutcomeUnknown
  case movePermanentlyRejected
  case moveRetryablyRejected
  case invalidDestinationUIDMapping(uid: Int64)
  case invalidSourceUIDMapping(uid: Int64)
  case invalidUIDValidityMapping(uidValidity: Int64)
  case reducedCapabilityMove(hasMove: Bool, hasUIDPlus: Bool)
  case reducedCapabilityMoveCopyRejected(retryable: Bool)
  case reducedCapabilityMoveMalformedCopyUID(ReducedCapabilityMalformedCopyUID)
  case repeatedSourceUIDMapping
  case sentAppendOutcomeUnknown
  case sentAppendFailsOnce
  case invalidSentAppendIdentity(uid: Int64, uidValidity: Int64)
  case missingSentAppendIdentity
  case sentAppendPermanentlyRejected
  case smtpCancellationReconnectMaximumTLS12
  case smtpStages([MailEngineSMTPStage])
  case startTLSAcknowledgedWithoutUpgrade(service: MailEngineService)
  case stateChangingOperationUntilCancelled
  case successful
  case uidValidityReset
  case xoauth2Challenge(service: MailEngineService)
}

enum ReducedCapabilityMalformedCopyUID: Sendable {
  case empty
  case invalidDestinationUID(Int64)
  case invalidDestinationUIDValidity(Int64)
  case invalidSourceUID(Int64)
  case mismatchedCardinality
  case mismatchedSourceUIDs
  case repeatedDestinationUID
  case repeatedSourceUID
}

enum MailEngineSMTPStage: Sendable {
  case accepted(serverMessageID: String?)
  case authenticationRejectedBeforeSubmission
  case cancelledAfterMessageContent
  case cancelledAfterSenderAccepted
  case cancelledBeforeSubmission
  case connectionLostAfterSubmission
  case dataRejectedBeforeSubmission(code: Int)
  case finalResponse(code: Int)
  case recipientRejectedAfterAccepted(code: Int)
  case recipientRejectedBeforeSubmission(code: Int)
  case senderRejectedBeforeSubmission(code: Int)
  case transportUnavailableAfterSenderAccepted
  case transportUnavailableBeforeSubmission
}

enum MailEngineQualificationEvent: Equatable, Sendable {
  case authenticationChallengeAnswered(connectionID: String, service: MailEngineService)
  case authenticationStarted(connectionID: String, service: MailEngineService)
  case authenticated(connectionID: String, service: MailEngineService)
  case bodyFetchCancelled(connectionID: String)
  case bodyFetchStarted(connectionID: String)
  case bodyPartsRequested(
    connectionID: String,
    message: MailEngineMessageIdentity,
    selectors: Set<MailEngineBodyPartSelector>
  )
  case closed(connectionID: String)
  case connectionSetupQuiesced(connectionID: String)
  case copyReceived(
    connectionID: String,
    sourceUIDs: [Int64],
    sourceUIDValidity: Int64,
    sourceMailbox: MailEngineMailboxIdentity,
    destinationMailbox: MailEngineMailboxIdentity
  )
  case idleCancelled(connectionID: String)
  case idleEventDelivered(connectionID: String, event: MailEngineIdleEvent)
  case idleLateCallbackAttempted(connectionID: String)
  case idleStarted(connectionID: String, mailbox: MailEngineMailboxIdentity)
  case metadataPageRequested(
    connectionID: String,
    mailbox: MailEngineMailboxIdentity,
    beforeUID: Int64?,
    limit: Int
  )
  case movePreservedUnrelatedDeletedUIDs(connectionID: String, uids: [Int64])
  case moveRemovedSourceUIDs(connectionID: String, uids: [Int64])
  case moveReceived(
    connectionID: String,
    sourceUIDs: [Int64],
    sourceUIDValidity: Int64,
    sourceMailbox: MailEngineMailboxIdentity,
    destinationMailbox: MailEngineMailboxIdentity
  )
  case serviceClosed(connectionID: String, service: MailEngineService)
  case sentAppend(connectionID: String)
  case sentAppendReceived(
    connectionID: String,
    mailbox: MailEngineMailboxIdentity,
    rawMessage: Data
  )
  case submitted(connectionID: String)
  case submissionEnvelopeAccepted(connectionID: String, envelope: MailEngineEnvelope)
  case submissionStarted(connectionID: String)
  case submissionContentAccepted(connectionID: String, rawMessage: Data)
  case submissionReceived(
    connectionID: String,
    envelope: MailEngineEnvelope,
    rawMessage: Data
  )
  case submissionTransportTerminated(connectionID: String)
  case tlsEstablished(
    connectionID: String,
    service: MailEngineService,
    version: MailEngineTLSVersion
  )
}

extension MailEngineQualificationEvent {
  func belongs(to connectionID: String, service: MailEngineService) -> Bool {
    switch self {
    case .authenticationChallengeAnswered(let eventConnectionID, let eventService),
      .authenticationStarted(let eventConnectionID, let eventService),
      .authenticated(let eventConnectionID, let eventService):
      eventConnectionID == connectionID && eventService == service
    case .tlsEstablished(let eventConnectionID, let eventService, _):
      eventConnectionID == connectionID && eventService == service
    case .serviceClosed(let eventConnectionID, let eventService):
      eventConnectionID == connectionID && eventService == service
    case .bodyFetchCancelled, .bodyFetchStarted, .bodyPartsRequested, .closed,
      .connectionSetupQuiesced, .copyReceived, .idleCancelled, .idleEventDelivered,
      .idleLateCallbackAttempted, .idleStarted, .metadataPageRequested,
      .movePreservedUnrelatedDeletedUIDs, .moveReceived, .moveRemovedSourceUIDs, .sentAppend,
      .sentAppendReceived, .submissionContentAccepted, .submissionEnvelopeAccepted,
      .submissionReceived, .submissionStarted, .submissionTransportTerminated, .submitted:
      false
    }
  }
}

struct MailEngineQualificationContract {
  let factory: any MailEngineQualificationCandidateFactory

  func verifySetupTransportAuthenticationAndCapabilities() async throws {
    verifyConfigurationTLSFloor()
    verifySnapshotEqualityIsOrderIndependent()
    let implicitConnection = try await connect(
      fixture: .successful,
      connectionID: "implicit-success",
      imapTransportMode: .implicitTLS,
      smtpTransportMode: .implicitTLS
    )
    let startTLSConnection = try await connect(
      fixture: .successful,
      authorization: .xoauth2(
        username: "oauth-success@example.com",
        accessToken: "oauth-success-token"
      ),
      connectionID: "starttls-success",
      imapTransportMode: .startTLS,
      smtpTransportMode: .startTLS
    )
    let mixedModeConnection = try await connect(
      fixture: .successful,
      connectionID: "mixed-mode-success",
      imapTransportMode: .implicitTLS,
      smtpTransportMode: .startTLS
    )
    let reverseMixedModeConnection = try await connect(
      fixture: .successful,
      connectionID: "reverse-mixed-mode-success",
      imapTransportMode: .startTLS,
      smtpTransportMode: .implicitTLS
    )
    let challengeConnections = try await connectXOAUTH2Challenges()
    let successfulSessions: [any MailEngineSession] =
      [
        implicitConnection.session,
        startTLSConnection.session,
        mixedModeConnection.session,
        reverseMixedModeConnection.session,
      ] + challengeConnections.map(\.session)
    verifySuccessfulSnapshots(
      [
        implicitConnection.snapshot,
        startTLSConnection.snapshot,
        mixedModeConnection.snapshot,
        reverseMixedModeConnection.snapshot,
      ] + challengeConnections.map(\.snapshot))
    await verifySetupEvents()
    withExtendedLifetime(successfulSessions) {}
  }

  private func verifyConfigurationTLSFloor() {
    let endpoint = MailEngineEndpoint(
      hostname: "mail.example.com",
      port: 993,
      transportMode: .implicitTLS
    )
    let configuration = MailEngineConfiguration(
      authorization: .password(username: "user@example.com", password: "password"),
      connectionID: "tls-floor",
      imapEndpoint: endpoint,
      minimumTLSVersion: .tls10,
      smtpEndpoint: endpoint
    )
    XCTAssertEqual(configuration.minimumTLSVersion, .tls12)
  }

  private func verifySnapshotEqualityIsOrderIndependent() {
    let inbox = MailEngineMailbox(
      identity: MailEngineMailboxIdentity("INBOX"),
      specialUses: []
    )
    let sent = MailEngineMailbox(
      identity: MailEngineMailboxIdentity("Sent"),
      specialUses: [.sent]
    )
    let first = MailEngineConnectionSnapshot(
      capabilities: [.idle],
      mailboxes: [inbox, sent],
      transportSecurity: [.imap: .tls13, .smtp: .tls12]
    )
    let reordered = MailEngineConnectionSnapshot(
      capabilities: [.idle],
      mailboxes: [sent, inbox],
      transportSecurity: [.imap: .tls13, .smtp: .tls12]
    )
    let repeatedInbox = MailEngineConnectionSnapshot(
      capabilities: [.idle],
      mailboxes: [inbox, inbox, sent],
      transportSecurity: [.imap: .tls13, .smtp: .tls12]
    )
    let repeatedSent = MailEngineConnectionSnapshot(
      capabilities: [.idle],
      mailboxes: [inbox, sent, sent],
      transportSecurity: [.imap: .tls13, .smtp: .tls12]
    )

    XCTAssertEqual(first, reordered)
    XCTAssertNotEqual(repeatedInbox, repeatedSent)
  }

  private func verifyXOAUTH2Challenge(
    service: MailEngineService,
    connectionID: String
  ) async throws -> (
    snapshot: MailEngineConnectionSnapshot,
    session: any MailEngineSession
  ) {
    try await connect(
      fixture: .xoauth2Challenge(service: service),
      authorization: .xoauth2(
        username: "oauth-challenge@example.com",
        accessToken: "oauth-challenge-token"
      ),
      connectionID: connectionID
    )
  }

  private func connectXOAUTH2Challenges() async throws -> [(
    snapshot: MailEngineConnectionSnapshot,
    session: any MailEngineSession
  )] {
    [
      try await verifyXOAUTH2Challenge(
        service: .imap,
        connectionID: "xoauth2-imap-challenge"
      ),
      try await verifyXOAUTH2Challenge(
        service: .smtp,
        connectionID: "xoauth2-smtp-challenge"
      ),
    ]
  }

  private func verifySuccessfulSnapshot(_ snapshot: MailEngineConnectionSnapshot) {
    assertMinimumTLS(snapshot)
    XCTAssertEqual(
      snapshot.capabilities,
      [.idle, .move, .specialUse, .uidPlus]
    )
    XCTAssertEqual(
      Dictionary(uniqueKeysWithValues: snapshot.mailboxes.map { ($0.identity, $0.specialUses) }),
      [
        MailEngineMailboxIdentity("INBOX"): [],
        MailEngineMailboxIdentity("Transmitted Items"): [.sent],
      ]
    )
  }

  private func verifySuccessfulSnapshots(_ snapshots: [MailEngineConnectionSnapshot]) {
    for snapshot in snapshots {
      verifySuccessfulSnapshot(snapshot)
    }
  }

  private func assertMinimumTLS(_ snapshot: MailEngineConnectionSnapshot) {
    XCTAssertEqual(Set(snapshot.transportSecurity.keys), [.imap, .smtp])
    for version in snapshot.transportSecurity.values {
      XCTAssertGreaterThanOrEqual(version, .tls12)
    }
  }

  private func verifySetupEvents() async {
    let events = await factory.events()
    for connectionID in [
      "implicit-success",
      "starttls-success",
      "mixed-mode-success",
      "reverse-mixed-mode-success",
    ] {
      assertSetupEvents(events, connectionID: connectionID, service: .imap)
      assertSetupEvents(events, connectionID: connectionID, service: .smtp)
    }
    assertSetupEvents(
      events,
      connectionID: "xoauth2-imap-challenge",
      service: .imap,
      includesChallenge: true
    )
    assertSetupEvents(events, connectionID: "xoauth2-imap-challenge", service: .smtp)
    assertSetupEvents(events, connectionID: "xoauth2-smtp-challenge", service: .imap)
    assertSetupEvents(
      events,
      connectionID: "xoauth2-smtp-challenge",
      service: .smtp,
      includesChallenge: true
    )
  }

  private func assertSetupEvents(
    _ events: [MailEngineQualificationEvent],
    connectionID: String,
    service: MailEngineService,
    includesChallenge: Bool = false
  ) {
    let serviceEvents = events.filter { $0.belongs(to: connectionID, service: service) }
    guard
      case .tlsEstablished(
        connectionID: connectionID,
        service: service,
        version: let negotiatedVersion
      ) = serviceEvents.first
    else {
      XCTFail("Secure transport must be established before authentication.")
      return
    }
    XCTAssertGreaterThanOrEqual(negotiatedVersion, .tls12)
    var expected = [
      MailEngineQualificationEvent.authenticationStarted(
        connectionID: connectionID,
        service: service
      )
    ]
    if includesChallenge {
      expected.append(
        .authenticationChallengeAnswered(connectionID: connectionID, service: service)
      )
    }
    expected.append(.authenticated(connectionID: connectionID, service: service))
    XCTAssertEqual(Array(serviceEvents.dropFirst()), expected)
  }

  func verifyTransportAndServerIdentityFailures() async throws {
    try await verifyTLSVersions()
    await verifySecurityAndAuthenticationFailures()
  }

  private func verifyTLSVersions() async throws {
    for service in [MailEngineService.imap, .smtp] {
      for transportMode in [MailEngineTransportMode.implicitTLS, .startTLS] {
        let tls12Connection = try await connect(
          fixture: .maximumTLS(service: service, version: .tls12),
          connectionID: "tls12-\(service)-\(transportMode)",
          imapTransportMode: transportMode,
          smtpTransportMode: transportMode
        )
        verifySuccessfulSnapshot(tls12Connection.snapshot)
        XCTAssertEqual(tls12Connection.snapshot.transportSecurity[service], .tls12)
        assertSetupEvents(
          await factory.events(),
          connectionID: "tls12-\(service)-\(transportMode)",
          service: service
        )
        await assertConnectionFails(
          fixture: .maximumTLS(service: service, version: .tls12),
          failedService: service,
          imapTransportMode: transportMode,
          minimumTLSVersion: .tls13,
          smtpTransportMode: transportMode,
          expectedError: .tlsVersionUnsupported
        )
        for legacyVersion in [MailEngineTLSVersion.tls10, .tls11] {
          await assertConnectionFails(
            fixture: .maximumTLS(service: service, version: legacyVersion),
            failedService: service,
            imapTransportMode: transportMode,
            smtpTransportMode: transportMode,
            expectedError: .tlsVersionUnsupported
          )
        }
      }
    }
  }

  private func verifySecurityAndAuthenticationFailures() async {
    for service in [MailEngineService.imap, .smtp] {
      for error in [
        MailEngineError.certificateRejected,
        .serverIdentityMismatch,
      ] {
        for transportMode in [MailEngineTransportMode.implicitTLS, .startTLS] {
          await assertConnectionFails(
            fixture: .connectionFailure(service: service, error: error),
            failedService: service,
            imapTransportMode: service == .imap ? transportMode : .implicitTLS,
            smtpTransportMode: service == .smtp ? transportMode : .implicitTLS,
            expectedError: error
          )
        }
      }
      await assertConnectionFails(
        fixture: .connectionFailure(service: service, error: .startTLSRejected),
        failedService: service,
        imapTransportMode: service == .imap ? .startTLS : .implicitTLS,
        smtpTransportMode: service == .smtp ? .startTLS : .implicitTLS,
        expectedError: .startTLSRejected
      )
      await assertConnectionFails(
        fixture: .startTLSAcknowledgedWithoutUpgrade(service: service),
        failedService: service,
        imapTransportMode: service == .imap ? .startTLS : .implicitTLS,
        smtpTransportMode: service == .smtp ? .startTLS : .implicitTLS,
        expectedError: .startTLSRejected
      )
      for authorization in [
        MailEngineAuthorization.password(
          username: "password-rejected@example.com",
          password: "rejected-password"
        ),
        .xoauth2(
          username: "oauth-rejected@example.com",
          accessToken: "oauth-rejected-token"
        ),
      ] {
        await assertConnectionFails(
          fixture: .connectionFailure(service: service, error: .authenticationRejected),
          authorization: authorization,
          failedService: service,
          expectedError: .authenticationRejected
        )
      }
    }
  }

  func verifyUIDMappings() async throws {
    let session = try await connect(fixture: .successful).session
    let inbox = MailEngineMailboxIdentity("INBOX")
    let archive = MailEngineMailboxIdentity("Archive")

    let copy = try await session.copy(
      messages: messageIdentities(
        connectionID: "connection-a",
        mailbox: inbox,
        uidValidity: 44,
        uids: [5, 4]
      ),
      to: archive
    )
    let move = try await session.move(
      messages: messageIdentities(
        connectionID: "connection-a",
        mailbox: inbox,
        uidValidity: 44,
        uids: [9, 8]
      ),
      to: archive
    )

    assertSuccessfulUIDMappings(copy: copy, move: move, inbox: inbox, archive: archive)
    await assertSuccessfulUIDCommands(inbox: inbox, archive: archive)
    try await verifyMixedMutationSources(inbox: inbox, archive: archive)
    try await verifyInvalidUIDMappings(inbox: inbox, archive: archive)
    try await verifyOverlappingUIDMutationIsolation(inbox: inbox)
    try await verifyPermanentIMAPRejection()
    try await verifyReducedCapabilityMoveSafety(inbox: inbox, archive: archive)
    try await verifyUnknownMutationOutcome(inbox: inbox, archive: archive)
    try await verifyUIDValidityReset(inbox: inbox, archive: archive)
  }

  private func assertSuccessfulUIDMappings(
    copy: MailEngineUIDMapping,
    move: MailEngineUIDMapping,
    inbox: MailEngineMailboxIdentity,
    archive: MailEngineMailboxIdentity
  ) {
    XCTAssertEqual(copy.sourceMailbox, inbox)
    XCTAssertEqual(copy.sourceUIDValidity, 44)
    XCTAssertEqual(copy.destinationMailbox, archive)
    XCTAssertEqual(copy.destinationUIDValidity, 91)
    XCTAssertEqual(
      Dictionary(uniqueKeysWithValues: copy.pairs.map { ($0.sourceUID, $0.destinationUID) }),
      [
        5: 105,
        4: 104,
      ]
    )
    XCTAssertEqual(move.sourceMailbox, inbox)
    XCTAssertEqual(move.sourceUIDValidity, 44)
    XCTAssertEqual(move.destinationMailbox, archive)
    XCTAssertEqual(move.destinationUIDValidity, 92)
    XCTAssertEqual(
      Dictionary(uniqueKeysWithValues: move.pairs.map { ($0.sourceUID, $0.destinationUID) }),
      [
        9: 209,
        8: 208,
      ]
    )
  }

  private func assertSuccessfulUIDCommands(
    inbox: MailEngineMailboxIdentity,
    archive: MailEngineMailboxIdentity
  ) async {
    let events = await factory.events()
    let mutationEvents = events.filter { event in
      switch event {
      case .copyReceived, .moveReceived:
        true
      default:
        false
      }
    }
    XCTAssertEqual(
      mutationEvents,
      [
        .copyReceived(
          connectionID: "connection-a",
          sourceUIDs: [5, 4],
          sourceUIDValidity: 44,
          sourceMailbox: inbox,
          destinationMailbox: archive
        ),
        .moveReceived(
          connectionID: "connection-a",
          sourceUIDs: [9, 8],
          sourceUIDValidity: 44,
          sourceMailbox: inbox,
          destinationMailbox: archive
        ),
      ],
      "Each successful UID mutation command must be sent exactly once."
    )
  }

  private func verifyMixedMutationSources(
    inbox: MailEngineMailboxIdentity,
    archive: MailEngineMailboxIdentity
  ) async throws {
    let connectionID = "mixed-mutation-source"
    let session = try await connect(
      fixture: .successful,
      connectionID: connectionID
    ).session
    let first = messageIdentity(connectionID, inbox, 4, 44)
    let mixedSources = [
      [first, messageIdentity(connectionID, archive, 5, 44)],
      [first, messageIdentity(connectionID, inbox, 5, 45)],
    ]
    for messages in mixedSources {
      do {
        _ = try await session.copy(messages: messages, to: archive)
        XCTFail("COPY must reject mixed source identities before reaching IMAP.")
      } catch {
        XCTAssertEqual(error as? MailEngineError, .staleMessageIdentity)
      }
      do {
        _ = try await session.move(messages: messages, to: archive)
        XCTFail("MOVE must reject mixed source identities before reaching IMAP.")
      } catch {
        XCTAssertEqual(error as? MailEngineError, .staleMessageIdentity)
      }
    }
    let mutationEvents = await mutationEvents(connectionID: connectionID)
    XCTAssertEqual(
      mutationEvents,
      [],
      "Mixed mailbox or UIDVALIDITY batches must be rejected before COPY or MOVE reaches IMAP."
    )
  }

  // swiftlint:disable:next function_body_length
  private func verifyUnknownMutationOutcome(
    inbox: MailEngineMailboxIdentity,
    archive: MailEngineMailboxIdentity
  ) async throws {
    let copySession = try await connect(
      fixture: .copyOutcomeUnknown,
      connectionID: "copy-outcome-unknown"
    ).session
    do {
      _ = try await copySession.copy(
        messages: messageIdentities(
          connectionID: "copy-outcome-unknown",
          mailbox: inbox,
          uidValidity: 44,
          uids: [5]
        ),
        to: archive
      )
      XCTFail("An indeterminate copy outcome must be classified for reconciliation.")
    } catch {
      XCTAssertEqual(error as? MailEngineError, .operationOutcomeUnknown)
    }
    await assertUnknownMutationReplayRejected("rewritten COPY") {
      _ = try await copySession.copy(
        messages: self.messageIdentities(
          connectionID: "copy-outcome-unknown",
          mailbox: inbox,
          uidValidity: 44,
          uids: [6]
        ),
        to: archive
      )
    }
    await assertUnknownMutationReplayRejected("rewritten MOVE") {
      _ = try await copySession.move(
        messages: self.messageIdentities(
          connectionID: "copy-outcome-unknown",
          mailbox: inbox,
          uidValidity: 44,
          uids: [7]
        ),
        to: archive
      )
    }
    let moveSession = try await connect(
      fixture: .moveOutcomeUnknown,
      connectionID: "move-outcome-unknown"
    ).session
    do {
      _ = try await moveSession.move(
        messages: messageIdentities(
          connectionID: "move-outcome-unknown",
          mailbox: inbox,
          uidValidity: 44,
          uids: [5]
        ),
        to: archive
      )
      XCTFail("An indeterminate move outcome must be classified for reconciliation.")
    } catch {
      XCTAssertEqual(error as? MailEngineError, .operationOutcomeUnknown)
    }
    await assertUnknownMutationReplayRejected("rewritten MOVE") {
      _ = try await moveSession.move(
        messages: self.messageIdentities(
          connectionID: "move-outcome-unknown",
          mailbox: inbox,
          uidValidity: 44,
          uids: [6]
        ),
        to: archive
      )
    }
    await assertUnknownMutationReplayRejected("rewritten COPY") {
      _ = try await moveSession.copy(
        messages: self.messageIdentities(
          connectionID: "move-outcome-unknown",
          mailbox: inbox,
          uidValidity: 44,
          uids: [7]
        ),
        to: archive
      )
    }
    try await verifyUnknownAppendOutcome()
    await assertUnknownMutationEvents()
  }

  private func assertUnknownMutationReplayRejected(
    _ operation: String,
    attempt: () async throws -> Void
  ) async {
    do {
      try await attempt()
      XCTFail("An uncertain mutation must block \(operation) until reconciliation.")
    } catch {
      XCTAssertEqual(error as? MailEngineError, .operationOutcomeUnknown)
    }
  }

  private func verifyUnknownAppendOutcome() async throws {
    let appendSession = try await connect(
      fixture: .sentAppendOutcomeUnknown,
      connectionID: "append-outcome-unknown"
    ).session
    do {
      _ = try await appendSession.appendToSent(
        Data("indeterminate append".utf8),
        mailbox: MailEngineMailboxIdentity("Sent")
      )
      XCTFail("An indeterminate Sent append must be classified for reconciliation.")
    } catch {
      XCTAssertEqual(error as? MailEngineError, .operationOutcomeUnknown)
    }
    await assertUnknownMutationReplayRejected("rewritten Sent append") {
      _ = try await appendSession.appendToSent(
        Data("rewritten indeterminate append".utf8),
        mailbox: MailEngineMailboxIdentity("Transmitted Items")
      )
    }
  }

  private func assertUnknownMutationEvents() async {
    let events = await factory.events()
    XCTAssertEqual(
      mutationEvents(in: events, connectionID: "copy-outcome-unknown"),
      [
        .copyReceived(
          connectionID: "copy-outcome-unknown",
          sourceUIDs: [5],
          sourceUIDValidity: 44,
          sourceMailbox: MailEngineMailboxIdentity("INBOX"),
          destinationMailbox: MailEngineMailboxIdentity("Archive")
        )
      ],
      "An uncertain COPY outcome must not replay through COPY or MOVE."
    )
    XCTAssertEqual(
      mutationEvents(in: events, connectionID: "move-outcome-unknown"),
      [
        .moveReceived(
          connectionID: "move-outcome-unknown",
          sourceUIDs: [5],
          sourceUIDValidity: 44,
          sourceMailbox: MailEngineMailboxIdentity("INBOX"),
          destinationMailbox: MailEngineMailboxIdentity("Archive")
        )
      ],
      "An uncertain MOVE outcome must not replay through MOVE or COPY."
    )
    XCTAssertEqual(
      events.filter {
        if case .sentAppendReceived(let connectionID, _, _) = $0 {
          return connectionID == "append-outcome-unknown"
        }
        return false
      }.count,
      1,
      "An uncertain Sent append must not replay any append command."
    )
  }

  private func mutationEvents(
    in events: [MailEngineQualificationEvent],
    connectionID: String
  ) -> [MailEngineQualificationEvent] {
    events.filter {
      switch $0 {
      case .copyReceived(let eventConnectionID, _, _, _, _),
        .moveReceived(let eventConnectionID, _, _, _, _):
        eventConnectionID == connectionID
      default:
        false
      }
    }
  }

  private func verifyUIDValidityReset(
    inbox: MailEngineMailboxIdentity,
    archive: MailEngineMailboxIdentity
  ) async throws {
    let session = try await connect(fixture: .uidValidityReset).session
    let archivePageBeforeReset = try await firstMetadataPage(session, mailbox: archive)
    let pageBeforeReset = try await firstMetadataPage(session, mailbox: inbox)
    let (peerSession, peerPageBeforeReset) = try await uidValidityPeer(inbox: inbox)
    let events = LockedBox<[MailEngineIdleEvent]>([])

    let resetTask = Task {
      try await session.idle(mailbox: inbox) { event in
        events.withValue { $0.append(event) }
      }
    }
    try await waitForIdleEvents(events, count: 1, timeout: .seconds(2))
    XCTAssertEqual(events.value, [.mailboxReset(uidValidity: 99)])
    try await assertUIDValidityPeerUnaffected(
      peerSession,
      pageBeforeReset: peerPageBeforeReset,
      inbox: inbox,
      archive: archive
    )
    await assertUIDValidityResetCancellation(
      resetTask,
      callbacks: events
    )
    XCTAssertEqual(archivePageBeforeReset.uidValidity, 73)
    await verifyStaleBodyFetchIsRejectedBeforeRequest(
      session: session,
      message: pageBeforeReset.messages[0].identity
    )
    await verifyStaleMutationInputs(
      session: session,
      message: pageBeforeReset.messages[0].identity,
      archive: archive
    )
    let pageAfterReset = try await session.loadMetadataPage(
      mailbox: inbox,
      beforeUID: nil,
      limit: 1
    )
    XCTAssertEqual(pageAfterReset.uidValidity, 99)
    XCTAssertEqual(pageAfterReset.messages[0].identity.uidValidity, 99)
    try await verifyResetIdentityIsUsable(
      session: session,
      message: pageAfterReset.messages[0].identity,
      archive: archive
    )
    try await verifyUnaffectedArchive(
      session: session,
      pageBeforeReset: archivePageBeforeReset,
      inbox: inbox
    )
  }

  private func assertUIDValidityResetCancellation(
    _ task: Task<Void, Error>,
    callbacks: LockedBox<[MailEngineIdleEvent]>
  ) async {
    let callbacksBeforeCancellation = callbacks.value
    await assertIdleCancellation(
      task,
      failureMessage: "UIDVALIDITY-reset IDLE must remain active until cancelled."
    )
    let cancellations = await idleCancellationEvents()
    XCTAssertTrue(
      cancellations.contains(.idleCancelled(connectionID: "connection-a")),
      "Cancelling UIDVALIDITY-reset IDLE must cancel its owning server command."
    )
    await assertNoDelayedCallbacks(
      callbacks,
      after: callbacksBeforeCancellation,
      connectionID: "connection-a",
      failureMessage: "UIDVALIDITY-reset IDLE must not deliver a delayed callback."
    )
  }

  private func verifyResetIdentityIsUsable(
    session: any MailEngineSession,
    message: MailEngineMessageIdentity,
    archive: MailEngineMailboxIdentity
  ) async throws {
    let parts = try await session.fetchBodyParts(
      [MailEngineBodyPartSelector("1.TEXT")],
      for: message
    )
    XCTAssertEqual(parts.map(\.data), [Data("INBOX-99-9-1.TEXT".utf8)])
    _ = try await session.copy(
      messages: [message],
      to: archive
    )
    _ = try await session.move(
      messages: [message],
      to: archive
    )
  }

  private func firstMetadataPage(
    _ session: any MailEngineSession,
    mailbox: MailEngineMailboxIdentity
  ) async throws -> MailEngineMetadataPage {
    try await session.loadMetadataPage(mailbox: mailbox, beforeUID: nil, limit: 1)
  }

  private func uidValidityPeer(
    inbox: MailEngineMailboxIdentity
  ) async throws -> (session: any MailEngineSession, page: MailEngineMetadataPage) {
    let session = try await connect(
      fixture: .successful,
      authorization: .xoauth2(
        username: "uidvalidity-peer@example.com",
        accessToken: "uidvalidity-peer-token"
      ),
      connectionID: "uidvalidity-peer"
    ).session
    let page = try await session.loadMetadataPage(mailbox: inbox, beforeUID: nil, limit: 1)
    return (session, page)
  }

  private func assertUIDValidityPeerUnaffected(
    _ session: any MailEngineSession,
    pageBeforeReset: MailEngineMetadataPage,
    inbox: MailEngineMailboxIdentity,
    archive: MailEngineMailboxIdentity
  ) async throws {
    let pageDuringReset = try await session.loadMetadataPage(
      mailbox: inbox,
      beforeUID: nil,
      limit: 1
    )
    XCTAssertEqual(pageDuringReset.uidValidity, pageBeforeReset.uidValidity)
    XCTAssertEqual(
      pageDuringReset.messages[0].identity,
      pageBeforeReset.messages[0].identity,
      "A UIDVALIDITY reset must not relabel another account's INBOX identity."
    )
    _ = try await session.fetchBodyParts(
      [MailEngineBodyPartSelector("1.TEXT")],
      for: pageBeforeReset.messages[0].identity
    )
    _ = try await session.copy(
      messages: [pageBeforeReset.messages[0].identity],
      to: archive
    )
    _ = try await session.move(
      messages: [pageBeforeReset.messages[0].identity],
      to: archive
    )
  }

  private func verifyStaleBodyFetchIsRejectedBeforeRequest(
    session: any MailEngineSession,
    message: MailEngineMessageIdentity
  ) async {
    let requestsBeforeStaleFetch = await factory.events().filter { event in
      if case .bodyPartsRequested(let connectionID, _, _) = event {
        return connectionID == "connection-a"
      }
      return false
    }.count
    do {
      _ = try await session.fetchBodyParts(
        [MailEngineBodyPartSelector("1.TEXT")],
        for: message
      )
      XCTFail("A message identity from the prior UIDVALIDITY must be rejected.")
    } catch {
      XCTAssertEqual(error as? MailEngineError, .staleMessageIdentity)
    }
    let requestsAfterStaleFetch = await factory.events().filter { event in
      if case .bodyPartsRequested(let connectionID, _, _) = event {
        return connectionID == "connection-a"
      }
      return false
    }.count
    XCTAssertEqual(
      requestsAfterStaleFetch,
      requestsBeforeStaleFetch,
      "A stale identity must be rejected before any body request reaches IMAP."
    )
  }

  private func verifyUnaffectedArchive(
    session: any MailEngineSession,
    pageBeforeReset: MailEngineMetadataPage,
    inbox: MailEngineMailboxIdentity
  ) async throws {
    let archiveParts = try await session.fetchBodyParts(
      [MailEngineBodyPartSelector("1.TEXT")],
      for: pageBeforeReset.messages[0].identity
    )
    XCTAssertEqual(
      archiveParts.map(\.data),
      [Data("Archive-73-9-1.TEXT".utf8)]
    )
    _ = try await session.copy(
      messages: [pageBeforeReset.messages[0].identity],
      to: inbox
    )
  }

  private func verifyStaleMutationInputs(
    session: any MailEngineSession,
    message: MailEngineMessageIdentity,
    archive: MailEngineMailboxIdentity
  ) async {
    let mutationEventsBefore = await factory.events().filter { event in
      switch event {
      case .copyReceived, .moveReceived:
        true
      default:
        false
      }
    }
    do {
      _ = try await session.copy(
        messages: [message],
        to: archive
      )
      XCTFail("A stale copy input must be rejected.")
    } catch {
      XCTAssertEqual(error as? MailEngineError, .staleMessageIdentity)
    }
    do {
      _ = try await session.move(
        messages: [message],
        to: archive
      )
      XCTFail("A stale move input must be rejected.")
    } catch {
      XCTAssertEqual(error as? MailEngineError, .staleMessageIdentity)
    }
    let mutationEventsAfter = await factory.events().filter { event in
      switch event {
      case .copyReceived, .moveReceived:
        true
      default:
        false
      }
    }
    XCTAssertEqual(
      mutationEventsAfter,
      mutationEventsBefore,
      "Stale mutation inputs must not send any COPY or MOVE command."
    )
  }

  // swiftlint:disable:next function_body_length
  private func verifyInvalidUIDMappings(
    inbox: MailEngineMailboxIdentity,
    archive: MailEngineMailboxIdentity
  ) async throws {
    XCTAssertThrowsError(
      try MailEngineUIDMapping.validated(
        sourceMailbox: inbox,
        sourceUIDValidity: 44,
        destinationMailbox: archive,
        requestedSourceUIDs: [],
        reported: MailEngineReportedUIDMapping(
          destinationUIDValidity: 45,
          destinationUIDs: [],
          sourceUIDs: []
        )
      )
    ) {
      XCTAssertEqual($0 as? MailEngineUIDMappingError, .invalidUID)
    }
    try await verifyEmptyUIDMappings(inbox: inbox, archive: archive)
    try await verifyMismatchedSourceUIDMappings(inbox: inbox, archive: archive)
    let malformedMoveSession = try await connect(fixture: .repeatedDestinationUIDMapping).session
    let malformedMoveCopyEvent = copyEvent(inbox: inbox, archive: archive)
    let malformedMoveCopyEvents = await mutationEvents(connectionID: "connection-a")
    do {
      _ = try await malformedMoveSession.copy(
        messages: messageIdentities(
          connectionID: "connection-a",
          mailbox: inbox,
          uidValidity: 44,
          uids: [4, 5]
        ),
        to: archive
      )
      XCTFail("The candidate must reject a COPYUID response with repeated destination UIDs.")
    } catch {
      XCTAssertEqual(error as? MailEngineUIDMappingError, .repeatedUID)
    }
    await assertOnlyNewMutationEvent(malformedMoveCopyEvent, after: malformedMoveCopyEvents)
    let malformedMoveEvent = moveEvent(inbox: inbox, archive: archive)
    let malformedMoveEvents = await mutationEvents(connectionID: "connection-a")
    do {
      _ = try await malformedMoveSession.move(
        messages: messageIdentities(
          connectionID: "connection-a",
          mailbox: inbox,
          uidValidity: 44,
          uids: [4, 5]
        ),
        to: archive
      )
      XCTFail("The candidate must reject a MOVEUID response with repeated destination UIDs.")
    } catch {
      XCTAssertEqual(error as? MailEngineUIDMappingError, .repeatedUID)
    }
    await assertOnlyNewMutationEvent(malformedMoveEvent, after: malformedMoveEvents)
    try await verifyRepeatedSourceUIDMapping(inbox: inbox, archive: archive)
    try await verifyMismatchedCardinalityMapping(inbox: inbox, archive: archive)
    try await verifyInvalidUIDValues(inbox: inbox, archive: archive)
  }

  private func verifyEmptyUIDMappings(
    inbox: MailEngineMailboxIdentity,
    archive: MailEngineMailboxIdentity
  ) async throws {
    let session = try await connect(fixture: .emptyUIDMapping).session
    for operation in ["copy", "move"] {
      do {
        if operation == "copy" {
          _ = try await session.copy(
            messages: messageIdentities(
              connectionID: "connection-a",
              mailbox: inbox,
              uidValidity: 44,
              uids: [4]
            ),
            to: archive
          )
        } else {
          _ = try await session.move(
            messages: messageIdentities(
              connectionID: "connection-a",
              mailbox: inbox,
              uidValidity: 44,
              uids: [4]
            ),
            to: archive
          )
        }
        XCTFail("The candidate must reject an empty \(operation.uppercased()) UID mapping.")
      } catch {
        XCTAssertEqual(error as? MailEngineUIDMappingError, .invalidUID)
      }
    }
  }

  private func verifyMismatchedSourceUIDMappings(
    inbox: MailEngineMailboxIdentity,
    archive: MailEngineMailboxIdentity
  ) async throws {
    let malformedCopySession = try await connect(fixture: .malformedCopyUIDMapping).session
    let malformedCopyEvent = copyEvent(inbox: inbox, archive: archive)
    let malformedCopyEvents = await mutationEvents(connectionID: "connection-a")
    do {
      _ = try await malformedCopySession.copy(
        messages: messageIdentities(
          connectionID: "connection-a",
          mailbox: inbox,
          uidValidity: 44,
          uids: [4, 5]
        ),
        to: archive
      )
      XCTFail("The candidate must reject a COPYUID response missing a requested UID.")
    } catch {
      XCTAssertEqual(error as? MailEngineUIDMappingError, .mismatchedSourceUIDs)
    }
    await assertOnlyNewMutationEvent(malformedCopyEvent, after: malformedCopyEvents)
    let malformedMoveSession = try await connect(
      fixture: .malformedCopyUIDMapping,
      connectionID: "mismatched-move-source"
    ).session
    let malformedMoveSourceEvent = moveEvent(
      connectionID: "mismatched-move-source",
      inbox: inbox,
      archive: archive
    )
    let malformedMoveSourceEvents = await mutationEvents(
      connectionID: "mismatched-move-source"
    )
    do {
      _ = try await malformedMoveSession.move(
        messages: messageIdentities(
          connectionID: "mismatched-move-source",
          mailbox: inbox,
          uidValidity: 44,
          uids: [4, 5]
        ),
        to: archive
      )
      XCTFail("The candidate must reject a MOVEUID response missing a requested UID.")
    } catch {
      XCTAssertEqual(error as? MailEngineUIDMappingError, .mismatchedSourceUIDs)
    }
    await assertOnlyNewMutationEvent(
      malformedMoveSourceEvent,
      after: malformedMoveSourceEvents,
      connectionID: "mismatched-move-source"
    )
  }

  private func verifyMismatchedCardinalityMapping(
    inbox: MailEngineMailboxIdentity,
    archive: MailEngineMailboxIdentity
  ) async throws {
    let mismatchedCardinalitySession = try await connect(
      fixture: .mismatchedUIDMappingCardinality
    ).session
    let copyEvent = copyEvent(inbox: inbox, archive: archive)
    let copyEvents = await mutationEvents(connectionID: "connection-a")
    do {
      _ = try await mismatchedCardinalitySession.copy(
        messages: messageIdentities(
          connectionID: "connection-a",
          mailbox: inbox,
          uidValidity: 44,
          uids: [4, 5]
        ),
        to: archive
      )
      XCTFail("The candidate must reject unequal source and destination UID counts.")
    } catch {
      XCTAssertEqual(error as? MailEngineUIDMappingError, .mismatchedCardinality)
    }
    await assertOnlyNewMutationEvent(
      copyEvent,
      after: copyEvents
    )
    let moveEvent = moveEvent(inbox: inbox, archive: archive)
    let moveEvents = await mutationEvents(connectionID: "connection-a")
    do {
      _ = try await mismatchedCardinalitySession.move(
        messages: messageIdentities(
          connectionID: "connection-a",
          mailbox: inbox,
          uidValidity: 44,
          uids: [4, 5]
        ),
        to: archive
      )
      XCTFail("The candidate must reject unequal MOVE source and destination UID counts.")
    } catch {
      XCTAssertEqual(error as? MailEngineUIDMappingError, .mismatchedCardinality)
    }
    await assertOnlyNewMutationEvent(
      moveEvent,
      after: moveEvents
    )
  }

  private func verifyRepeatedSourceUIDMapping(
    inbox: MailEngineMailboxIdentity,
    archive: MailEngineMailboxIdentity
  ) async throws {
    let session = try await connect(fixture: .repeatedSourceUIDMapping).session
    let copyEvent = copyEvent(inbox: inbox, archive: archive)
    let previousCopyEvents = await mutationEvents(connectionID: "connection-a")
    do {
      _ = try await session.copy(
        messages: messageIdentities(
          connectionID: "connection-a",
          mailbox: inbox,
          uidValidity: 44,
          uids: [4, 5]
        ),
        to: archive
      )
      XCTFail("The candidate must reject a COPYUID response with repeated source UIDs.")
    } catch {
      XCTAssertEqual(error as? MailEngineUIDMappingError, .repeatedUID)
    }
    await assertOnlyNewMutationEvent(copyEvent, after: previousCopyEvents)
    let event = moveEvent(inbox: inbox, archive: archive)
    let previousEvents = await mutationEvents(connectionID: "connection-a")
    do {
      _ = try await session.move(
        messages: messageIdentities(
          connectionID: "connection-a",
          mailbox: inbox,
          uidValidity: 44,
          uids: [4, 5]
        ),
        to: archive
      )
      XCTFail("The candidate must reject a MOVEUID response with repeated source UIDs.")
    } catch {
      XCTAssertEqual(error as? MailEngineUIDMappingError, .repeatedUID)
    }
    await assertOnlyNewMutationEvent(event, after: previousEvents)
  }

  private func verifyInvalidUIDValues(
    inbox: MailEngineMailboxIdentity,
    archive: MailEngineMailboxIdentity
  ) async throws {
    for invalidUID in [Int64(0), -1, 4_294_967_296] {
      for fixture in [
        MailEngineQualificationFixture.invalidDestinationUIDMapping(uid: invalidUID),
        .invalidSourceUIDMapping(uid: invalidUID),
      ] {
        let invalidUIDSession = try await connect(fixture: fixture).session
        let event = copyEvent(inbox: inbox, archive: archive)
        let previousEvents = await mutationEvents(connectionID: "connection-a")
        do {
          _ = try await invalidUIDSession.copy(
            messages: messageIdentities(
              connectionID: "connection-a",
              mailbox: inbox,
              uidValidity: 44,
              uids: [4, 5]
            ),
            to: archive
          )
          XCTFail("The candidate must reject UIDs outside the IMAP protocol range.")
        } catch {
          XCTAssertEqual(error as? MailEngineUIDMappingError, .invalidUID)
        }
        await assertOnlyNewMutationEvent(event, after: previousEvents)

        let invalidUIDMoveSession = try await connect(fixture: fixture).session
        let moveEvent = moveEvent(inbox: inbox, archive: archive)
        let previousMoveEvents = await mutationEvents(connectionID: "connection-a")
        do {
          _ = try await invalidUIDMoveSession.move(
            messages: messageIdentities(
              connectionID: "connection-a",
              mailbox: inbox,
              uidValidity: 44,
              uids: [4, 5]
            ),
            to: archive
          )
          XCTFail("The candidate must reject MOVE UIDs outside the IMAP protocol range.")
        } catch {
          XCTAssertEqual(error as? MailEngineUIDMappingError, .invalidUID)
        }
        await assertOnlyNewMutationEvent(moveEvent, after: previousMoveEvents)
      }
    }
    try await verifyInvalidUIDValidityValues(inbox: inbox, archive: archive)
  }

  private func verifyInvalidUIDValidityValues(
    inbox: MailEngineMailboxIdentity,
    archive: MailEngineMailboxIdentity
  ) async throws {
    for invalidUIDValidity in [Int64(0), -1, 4_294_967_296] {
      try await verifyInvalidDestinationUIDValidity(
        invalidUIDValidity,
        inbox: inbox,
        archive: archive
      )
      try await verifyInvalidSourceUIDValidity(
        invalidUIDValidity,
        inbox: inbox,
        archive: archive
      )
    }
  }

  private func verifyInvalidDestinationUIDValidity(
    _ invalidUIDValidity: Int64,
    inbox: MailEngineMailboxIdentity,
    archive: MailEngineMailboxIdentity
  ) async throws {
    let invalidUIDValiditySession = try await connect(
      fixture: .invalidUIDValidityMapping(uidValidity: invalidUIDValidity)
    ).session
    let event = copyEvent(inbox: inbox, archive: archive)
    let previousEvents = await mutationEvents(connectionID: "connection-a")
    do {
      _ = try await invalidUIDValiditySession.copy(
        messages: messageIdentities(
          connectionID: "connection-a",
          mailbox: inbox,
          uidValidity: 44,
          uids: [4, 5]
        ),
        to: archive
      )
      XCTFail("The candidate must reject destination UIDVALIDITY outside the IMAP range.")
    } catch {
      XCTAssertEqual(error as? MailEngineUIDMappingError, .invalidDestinationUIDValidity)
    }
    await assertOnlyNewMutationEvent(event, after: previousEvents)

    let invalidUIDValidityMoveSession = try await connect(
      fixture: .invalidUIDValidityMapping(uidValidity: invalidUIDValidity)
    ).session
    let moveEvent = moveEvent(inbox: inbox, archive: archive)
    let previousMoveEvents = await mutationEvents(connectionID: "connection-a")
    do {
      _ = try await invalidUIDValidityMoveSession.move(
        messages: messageIdentities(
          connectionID: "connection-a",
          mailbox: inbox,
          uidValidity: 44,
          uids: [4, 5]
        ),
        to: archive
      )
      XCTFail("The candidate must reject MOVE UIDVALIDITY outside the IMAP range.")
    } catch {
      XCTAssertEqual(error as? MailEngineUIDMappingError, .invalidDestinationUIDValidity)
    }
    await assertOnlyNewMutationEvent(moveEvent, after: previousMoveEvents)
  }

  private func verifyInvalidSourceUIDValidity(
    _ invalidUIDValidity: Int64,
    inbox: MailEngineMailboxIdentity,
    archive: MailEngineMailboxIdentity
  ) async throws {
    let sourceConnectionID = "invalid-source-uidvalidity-\(invalidUIDValidity)"
    let invalidSourceSession = try await connect(
      fixture: .successful,
      connectionID: sourceConnectionID
    ).session
    do {
      _ = try await invalidSourceSession.copy(
        messages: messageIdentities(
          connectionID: sourceConnectionID,
          mailbox: inbox,
          uidValidity: invalidUIDValidity,
          uids: [4, 5]
        ),
        to: archive
      )
      XCTFail("The candidate must reject source UIDVALIDITY outside the IMAP range.")
    } catch {
      XCTAssertEqual(error as? MailEngineUIDMappingError, .invalidSourceUIDValidity)
    }
    do {
      _ = try await invalidSourceSession.move(
        messages: messageIdentities(
          connectionID: sourceConnectionID,
          mailbox: inbox,
          uidValidity: invalidUIDValidity,
          uids: [4, 5]
        ),
        to: archive
      )
      XCTFail("The candidate must reject MOVE source UIDVALIDITY outside the IMAP range.")
    } catch {
      XCTAssertEqual(error as? MailEngineUIDMappingError, .invalidSourceUIDValidity)
    }
    let sourceMutationEvents = await factory.events().filter {
      switch $0 {
      case .copyReceived(let connectionID, _, _, _, _),
        .moveReceived(let connectionID, _, _, _, _):
        return connectionID == sourceConnectionID
      default:
        return false
      }
    }
    XCTAssertEqual(
      sourceMutationEvents,
      [],
      "Invalid source UIDVALIDITY must be rejected before a mutation reaches IMAP."
    )
  }

  private func verifyOverlappingUIDMutationIsolation(
    inbox: MailEngineMailboxIdentity
  ) async throws {
    let firstArchive = MailEngineMailboxIdentity("First Archive")
    let secondArchive = MailEngineMailboxIdentity("Second Archive")
    try await verifyOverlappingCopies(
      inbox: inbox,
      firstArchive: firstArchive,
      secondArchive: secondArchive
    )
    try await verifyOverlappingMoves(
      inbox: inbox,
      firstArchive: firstArchive,
      secondArchive: secondArchive
    )
    await assertOverlappingUIDMutationEvents(
      inbox: inbox,
      firstArchive: firstArchive,
      secondArchive: secondArchive
    )
  }

  private func verifyOverlappingCopies(
    inbox: MailEngineMailboxIdentity,
    firstArchive: MailEngineMailboxIdentity,
    secondArchive: MailEngineMailboxIdentity
  ) async throws {
    let firstCopySession = try await connect(
      fixture: .overlappingCopyResults,
      connectionID: "copy-connection-one"
    ).session
    let secondCopySession = try await connect(
      fixture: .overlappingCopyResults,
      connectionID: "copy-connection-two"
    ).session
    async let firstCopy = firstCopySession.copy(
      messages: messageIdentities(
        connectionID: "copy-connection-one",
        mailbox: inbox,
        uidValidity: 44,
        uids: [19]
      ),
      to: firstArchive
    )
    async let secondCopy = secondCopySession.copy(
      messages: messageIdentities(
        connectionID: "copy-connection-two",
        mailbox: inbox,
        uidValidity: 44,
        uids: [29]
      ),
      to: secondArchive
    )
    let copyMappings = try await (firstCopy, secondCopy)
    XCTAssertEqual(copyMappings.0.pairs, [.init(destinationUID: 119, sourceUID: 19)])
    XCTAssertEqual(copyMappings.1.pairs, [.init(destinationUID: 129, sourceUID: 29)])
  }

  private func verifyOverlappingMoves(
    inbox: MailEngineMailboxIdentity,
    firstArchive: MailEngineMailboxIdentity,
    secondArchive: MailEngineMailboxIdentity
  ) async throws {
    let firstMoveSession = try await connect(
      fixture: .overlappingMoveResults,
      connectionID: "move-connection-one"
    ).session
    let secondMoveSession = try await connect(
      fixture: .overlappingMoveResults,
      connectionID: "move-connection-two"
    ).session
    async let firstMove = firstMoveSession.move(
      messages: messageIdentities(
        connectionID: "move-connection-one",
        mailbox: inbox,
        uidValidity: 44,
        uids: [19]
      ),
      to: firstArchive
    )
    async let secondMove = secondMoveSession.move(
      messages: messageIdentities(
        connectionID: "move-connection-two",
        mailbox: inbox,
        uidValidity: 44,
        uids: [29]
      ),
      to: secondArchive
    )
    let moveMappings = try await (firstMove, secondMove)
    XCTAssertEqual(moveMappings.0.pairs, [.init(destinationUID: 219, sourceUID: 19)])
    XCTAssertEqual(moveMappings.1.pairs, [.init(destinationUID: 229, sourceUID: 29)])
  }

  private func assertOverlappingUIDMutationEvents(
    inbox: MailEngineMailboxIdentity,
    firstArchive: MailEngineMailboxIdentity,
    secondArchive: MailEngineMailboxIdentity
  ) async {
    let events = await factory.events().filter { event in
      switch event {
      case .copyReceived(let connectionID, _, _, _, _),
        .moveReceived(let connectionID, _, _, _, _):
        connectionID.hasPrefix("copy-connection-") || connectionID.hasPrefix("move-connection-")
      default:
        false
      }
    }
    assertExactlyOnce(
      events,
      events:
        .copyReceived(
          connectionID: "copy-connection-one",
          sourceUIDs: [19],
          sourceUIDValidity: 44,
          sourceMailbox: inbox,
          destinationMailbox: firstArchive
        ),
      .copyReceived(
        connectionID: "copy-connection-two",
        sourceUIDs: [29],
        sourceUIDValidity: 44,
        sourceMailbox: inbox,
        destinationMailbox: secondArchive
      ),
      .moveReceived(
        connectionID: "move-connection-one",
        sourceUIDs: [19],
        sourceUIDValidity: 44,
        sourceMailbox: inbox,
        destinationMailbox: firstArchive
      ),
      .moveReceived(
        connectionID: "move-connection-two",
        sourceUIDs: [29],
        sourceUIDValidity: 44,
        sourceMailbox: inbox,
        destinationMailbox: secondArchive
      )
    )
  }

  private func copyEvent(
    inbox: MailEngineMailboxIdentity,
    archive: MailEngineMailboxIdentity
  ) -> MailEngineQualificationEvent {
    .copyReceived(
      connectionID: "connection-a",
      sourceUIDs: [4, 5],
      sourceUIDValidity: 44,
      sourceMailbox: inbox,
      destinationMailbox: archive
    )
  }

  private func moveEvent(
    connectionID: String = "connection-a",
    inbox: MailEngineMailboxIdentity,
    archive: MailEngineMailboxIdentity
  ) -> MailEngineQualificationEvent {
    .moveReceived(
      connectionID: connectionID,
      sourceUIDs: [4, 5],
      sourceUIDValidity: 44,
      sourceMailbox: inbox,
      destinationMailbox: archive
    )
  }

  private func mutationEvents(connectionID: String) async -> [MailEngineQualificationEvent] {
    await factory.events().filter {
      switch $0 {
      case .copyReceived(let eventConnectionID, _, _, _, _),
        .moveReceived(let eventConnectionID, _, _, _, _):
        eventConnectionID == connectionID
      default:
        false
      }
    }
  }

  private func assertOnlyNewMutationEvent(
    _ event: MailEngineQualificationEvent,
    after previousEvents: [MailEngineQualificationEvent],
    connectionID: String = "connection-a"
  ) async {
    let currentEvents = await mutationEvents(connectionID: connectionID)
    XCTAssertEqual(
      currentEvents,
      previousEvents + [event],
      "A malformed UID mapping must not cause any connection-scoped mutation retry."
    )
  }

  private func verifyPermanentIMAPRejection() async throws {
    try await verifyPermanentAppendRejection()
    try await verifyPermanentCopyRejection()
    try await verifyPermanentMoveRejection()
    try await verifyRetryableCopyRejection()
    try await verifyRetryableMoveRejection()
  }

  private func verifyPermanentAppendRejection() async throws {
    let appendConnectionID = "permanent-append-rejection"
    let rawMessage = Data("permanently rejected".utf8)
    let sentMailbox = MailEngineMailboxIdentity("Sent")
    let session = try await connect(
      fixture: .sentAppendPermanentlyRejected,
      connectionID: appendConnectionID
    ).session
    do {
      _ = try await session.appendToSent(
        rawMessage,
        mailbox: sentMailbox
      )
      XCTFail("A permanent tagged IMAP rejection must preserve its classification.")
    } catch {
      XCTAssertEqual(
        error as? MailEngineError,
        .protocolRejected(code: "NOPERM", retryable: false)
      )
    }
    let events = await factory.events()
    XCTAssertEqual(
      events.filter {
        if case .sentAppendReceived(let connectionID, _, _) = $0 {
          return connectionID == appendConnectionID
        }
        return false
      }.count,
      1,
      "A permanent Sent append rejection must not retry with rewritten arguments."
    )
  }

  private func verifyPermanentCopyRejection() async throws {
    let inbox = MailEngineMailboxIdentity("INBOX")
    let archive = MailEngineMailboxIdentity("Archive")
    let copyConnectionID = "permanent-copy-rejection"
    let copySession = try await connect(
      fixture: .copyPermanentlyRejected,
      connectionID: copyConnectionID
    ).session
    do {
      _ = try await copySession.copy(
        messages: messageIdentities(
          connectionID: copyConnectionID,
          mailbox: inbox,
          uidValidity: 44,
          uids: [5]
        ),
        to: archive
      )
      XCTFail("A permanent COPY rejection must be preserved.")
    } catch {
      XCTAssertEqual(
        error as? MailEngineError,
        .protocolRejected(code: "NOPERM", retryable: false)
      )
    }
    let events = await factory.events()
    XCTAssertEqual(
      mutationEvents(in: events, connectionID: copyConnectionID),
      [
        .copyReceived(
          connectionID: copyConnectionID,
          sourceUIDs: [5],
          sourceUIDValidity: 44,
          sourceMailbox: inbox,
          destinationMailbox: archive
        )
      ],
      "A permanent COPY rejection must not retry through COPY or MOVE."
    )
  }

  private func verifyPermanentMoveRejection() async throws {
    let inbox = MailEngineMailboxIdentity("INBOX")
    let archive = MailEngineMailboxIdentity("Archive")
    let moveConnectionID = "permanent-move-rejection"
    let moveSession = try await connect(
      fixture: .movePermanentlyRejected,
      connectionID: moveConnectionID
    ).session
    do {
      _ = try await moveSession.move(
        messages: messageIdentities(
          connectionID: moveConnectionID,
          mailbox: inbox,
          uidValidity: 44,
          uids: [9]
        ),
        to: archive
      )
      XCTFail("A permanent MOVE rejection must be preserved.")
    } catch {
      XCTAssertEqual(
        error as? MailEngineError,
        .protocolRejected(code: "NOPERM", retryable: false)
      )
    }
    let events = await factory.events()
    XCTAssertEqual(
      mutationEvents(in: events, connectionID: moveConnectionID),
      [
        .moveReceived(
          connectionID: moveConnectionID,
          sourceUIDs: [9],
          sourceUIDValidity: 44,
          sourceMailbox: inbox,
          destinationMailbox: archive
        )
      ],
      "A permanent MOVE rejection must not retry through MOVE or COPY."
    )
  }

  private func verifyRetryableCopyRejection() async throws {
    let connectionID = "retryable-copy-rejection"
    let session = try await connect(
      fixture: .copyRetryablyRejected,
      connectionID: connectionID
    ).session
    do {
      _ = try await session.copy(
        messages: messageIdentities(
          connectionID: connectionID,
          mailbox: MailEngineMailboxIdentity("INBOX"),
          uidValidity: 44,
          uids: [5]
        ),
        to: MailEngineMailboxIdentity("Archive")
      )
      XCTFail("A retryable COPY rejection must be preserved.")
    } catch {
      XCTAssertEqual(
        error as? MailEngineError,
        .protocolRejected(code: "TRYAGAIN", retryable: true)
      )
    }
    let mutationEvents = await mutationEvents(connectionID: connectionID)
    XCTAssertEqual(
      mutationEvents,
      [
        .copyReceived(
          connectionID: connectionID,
          sourceUIDs: [5],
          sourceUIDValidity: 44,
          sourceMailbox: MailEngineMailboxIdentity("INBOX"),
          destinationMailbox: MailEngineMailboxIdentity("Archive")
        )
      ],
      "A retryable COPY rejection must not retry through COPY or MOVE."
    )
  }

  private func verifyRetryableMoveRejection() async throws {
    let connectionID = "retryable-move-rejection"
    let session = try await connect(
      fixture: .moveRetryablyRejected,
      connectionID: connectionID
    ).session
    do {
      _ = try await session.move(
        messages: messageIdentities(
          connectionID: connectionID,
          mailbox: MailEngineMailboxIdentity("INBOX"),
          uidValidity: 44,
          uids: [9]
        ),
        to: MailEngineMailboxIdentity("Archive")
      )
      XCTFail("A retryable MOVE rejection must be preserved.")
    } catch {
      XCTAssertEqual(
        error as? MailEngineError,
        .protocolRejected(code: "TRYAGAIN", retryable: true)
      )
    }
    let mutationEvents = await mutationEvents(connectionID: connectionID)
    XCTAssertEqual(
      mutationEvents,
      [
        .moveReceived(
          connectionID: connectionID,
          sourceUIDs: [9],
          sourceUIDValidity: 44,
          sourceMailbox: MailEngineMailboxIdentity("INBOX"),
          destinationMailbox: MailEngineMailboxIdentity("Archive")
        )
      ],
      "A retryable MOVE rejection must not retry through MOVE or COPY."
    )
  }

  private func verifyReducedCapabilityMoveSafety(
    inbox: MailEngineMailboxIdentity,
    archive: MailEngineMailboxIdentity
  ) async throws {
    let profiles = [
      (connectionID: "move-without-uidplus", hasMove: true, hasUIDPlus: false),
      (connectionID: "copy-delete-with-uidplus", hasMove: false, hasUIDPlus: true),
      (connectionID: "move-without-capabilities", hasMove: false, hasUIDPlus: false),
    ]
    for profile in profiles {
      try await verifyReducedCapabilityMoveProfile(
        connectionID: profile.connectionID,
        hasMove: profile.hasMove,
        hasUIDPlus: profile.hasUIDPlus,
        inbox: inbox,
        archive: archive
      )
    }
    try await verifyMalformedReducedCapabilityCopyUID(inbox: inbox, archive: archive)
    try await verifyReducedCapabilityCopyRejections(inbox: inbox, archive: archive)
  }

  private func verifyReducedCapabilityCopyRejections(
    inbox: MailEngineMailboxIdentity,
    archive: MailEngineMailboxIdentity
  ) async throws {
    for retryable in [false, true] {
      let connectionID = "copy-delete-copy-rejected-\(retryable)"
      let session = try await connect(
        fixture: .reducedCapabilityMoveCopyRejected(retryable: retryable),
        connectionID: connectionID
      ).session
      do {
        _ = try await session.move(
          messages: messageIdentities(
            connectionID: connectionID,
            mailbox: inbox,
            uidValidity: 44,
            uids: [9]
          ),
          to: archive
        )
        XCTFail("A rejected fallback COPY must fail without source removal.")
      } catch {
        XCTAssertEqual(
          error as? MailEngineError,
          .protocolRejected(
            code: retryable ? "TRYAGAIN" : "NOPERM",
            retryable: retryable
          )
        )
      }
      await assertRejectedReducedCapabilityCopyEvents(
        connectionID: connectionID,
        inbox: inbox,
        archive: archive
      )
    }
  }

  private func assertRejectedReducedCapabilityCopyEvents(
    connectionID: String,
    inbox: MailEngineMailboxIdentity,
    archive: MailEngineMailboxIdentity
  ) async {
    let events = await mutationEvents(connectionID: connectionID)
    XCTAssertEqual(
      events,
      [
        .copyReceived(
          connectionID: connectionID,
          sourceUIDs: [9],
          sourceUIDValidity: 44,
          sourceMailbox: inbox,
          destinationMailbox: archive
        )
      ],
      "A rejected fallback COPY must not delete or expunge any source message."
    )
  }

  private func verifyMalformedReducedCapabilityCopyUID(
    inbox: MailEngineMailboxIdentity,
    archive: MailEngineMailboxIdentity
  ) async throws {
    for (index, testCase) in malformedReducedCapabilityFixtures.enumerated() {
      try await verifyMalformedReducedCapabilityCopyUID(
        testCase,
        index: index,
        inbox: inbox,
        archive: archive
      )
    }
  }

  private var malformedReducedCapabilityFixtures:
    [(ReducedCapabilityMalformedCopyUID, MailEngineUIDMappingError)]
  {
    let invalidUIDs = [Int64(-1), 0, 4_294_967_296]
    return
      [
        (.empty, .invalidUID),
        (.mismatchedSourceUIDs, .mismatchedSourceUIDs),
        (.repeatedDestinationUID, .repeatedUID),
        (.repeatedSourceUID, .repeatedUID),
        (.mismatchedCardinality, .mismatchedCardinality),
      ]
      + invalidUIDs.flatMap {
        [
          (.invalidDestinationUID($0), .invalidUID),
          (.invalidSourceUID($0), .invalidUID),
          (.invalidDestinationUIDValidity($0), .invalidDestinationUIDValidity),
        ]
      }
  }

  private func verifyMalformedReducedCapabilityCopyUID(
    _ testCase: (ReducedCapabilityMalformedCopyUID, MailEngineUIDMappingError),
    index: Int,
    inbox: MailEngineMailboxIdentity,
    archive: MailEngineMailboxIdentity
  ) async throws {
    let connectionID = "copy-delete-malformed-copyuid-\(index)"
    let session = try await connect(
      fixture: .reducedCapabilityMoveMalformedCopyUID(testCase.0),
      connectionID: connectionID
    ).session
    do {
      _ = try await session.move(
        messages: messageIdentities(
          connectionID: connectionID,
          mailbox: inbox,
          uidValidity: 44,
          uids: [4, 5]
        ),
        to: archive
      )
      XCTFail("The UIDPLUS fallback must reject malformed COPYUID before source removal.")
    } catch {
      XCTAssertEqual(error as? MailEngineUIDMappingError, testCase.1)
    }
    await assertMalformedReducedCapabilityEvents(
      connectionID: connectionID,
      inbox: inbox,
      archive: archive
    )
  }

  private func assertMalformedReducedCapabilityEvents(
    connectionID: String,
    inbox: MailEngineMailboxIdentity,
    archive: MailEngineMailboxIdentity
  ) async {
    let events = await factory.events()
    XCTAssertEqual(
      mutationEvents(in: events, connectionID: connectionID),
      [
        .copyReceived(
          connectionID: connectionID,
          sourceUIDs: [4, 5],
          sourceUIDValidity: 44,
          sourceMailbox: inbox,
          destinationMailbox: archive
        )
      ],
      "Malformed COPYUID must not retry the destination copy through any mutation command."
    )
    XCTAssertFalse(
      events.contains {
        if case .moveRemovedSourceUIDs(let eventConnectionID, _) = $0 {
          return eventConnectionID == connectionID
        }
        return false
      },
      "Malformed COPYUID must not remove or expunge any source message."
    )
  }

  private func verifyReducedCapabilityMoveProfile(
    connectionID: String,
    hasMove: Bool,
    hasUIDPlus: Bool,
    inbox: MailEngineMailboxIdentity,
    archive: MailEngineMailboxIdentity
  ) async throws {
    let connection = try await connect(
      fixture: .reducedCapabilityMove(hasMove: hasMove, hasUIDPlus: hasUIDPlus),
      connectionID: connectionID
    )
    var expectedCapabilities: Set<MailEngineCapability> = [.idle, .specialUse]
    if hasMove { expectedCapabilities.insert(.move) }
    if hasUIDPlus { expectedCapabilities.insert(.uidPlus) }
    XCTAssertEqual(connection.snapshot.capabilities, expectedCapabilities)
    XCTAssertEqual(
      Dictionary(
        uniqueKeysWithValues: connection.snapshot.mailboxes.map {
          ($0.identity, $0.specialUses)
        }
      ),
      [
        MailEngineMailboxIdentity("INBOX"): [],
        MailEngineMailboxIdentity("Transmitted Items"): [.sent],
      ]
    )
    assertMinimumTLS(connection.snapshot)
    guard hasMove || hasUIDPlus else {
      await assertMoveUnsupported(
        connection.session,
        connectionID: connectionID,
        inbox: inbox,
        archive: archive
      )
      return
    }

    let mapping = try await connection.session.move(
      messages: messageIdentities(
        connectionID: connectionID,
        mailbox: inbox,
        uidValidity: 44,
        uids: [9, 8]
      ),
      to: archive
    )
    assertReducedCapabilityMoveMapping(mapping, inbox: inbox, archive: archive)
    await assertReducedCapabilityMutationEvents(
      connectionID: connectionID,
      hasMove: hasMove,
      inbox: inbox,
      archive: archive
    )
  }

  private func assertReducedCapabilityMutationEvents(
    connectionID: String,
    hasMove: Bool,
    inbox: MailEngineMailboxIdentity,
    archive: MailEngineMailboxIdentity
  ) async {
    let profileEvents = await factory.events().filter { event in
      switch event {
      case .copyReceived(let eventConnectionID, _, _, _, _),
        .moveReceived(let eventConnectionID, _, _, _, _),
        .movePreservedUnrelatedDeletedUIDs(let eventConnectionID, _),
        .moveRemovedSourceUIDs(let eventConnectionID, _):
        eventConnectionID == connectionID
      default:
        false
      }
    }
    let expectedMutation: MailEngineQualificationEvent =
      if hasMove {
        .moveReceived(
          connectionID: connectionID,
          sourceUIDs: [9, 8],
          sourceUIDValidity: 44,
          sourceMailbox: inbox,
          destinationMailbox: archive
        )
      } else {
        .copyReceived(
          connectionID: connectionID,
          sourceUIDs: [9, 8],
          sourceUIDValidity: 44,
          sourceMailbox: inbox,
          destinationMailbox: archive
        )
      }
    var expectedEvents = [expectedMutation]
    if !hasMove {
      expectedEvents.append(
        .moveRemovedSourceUIDs(connectionID: connectionID, uids: [9, 8])
      )
    }
    expectedEvents.append(
      .movePreservedUnrelatedDeletedUIDs(connectionID: connectionID, uids: [6])
    )
    XCTAssertEqual(
      profileEvents,
      expectedEvents,
      "Reduced-capability removal must not expunge unrelated deleted messages."
    )
  }

  private func assertMoveUnsupported(
    _ session: any MailEngineSession,
    connectionID: String,
    inbox: MailEngineMailboxIdentity,
    archive: MailEngineMailboxIdentity
  ) async {
    do {
      _ = try await session.move(
        messages: messageIdentities(
          connectionID: connectionID,
          mailbox: inbox,
          uidValidity: 44,
          uids: [9]
        ),
        to: archive
      )
      XCTFail("Move must be unsupported without MOVE or UIDPLUS.")
    } catch {
      XCTAssertEqual(error as? MailEngineError, .operationUnsupported)
    }
    let events = await factory.events()
    XCTAssertFalse(
      events.contains { event in
        switch event {
        case .copyReceived(let eventConnectionID, _, _, _, _),
          .moveReceived(let eventConnectionID, _, _, _, _),
          .movePreservedUnrelatedDeletedUIDs(let eventConnectionID, _),
          .moveRemovedSourceUIDs(let eventConnectionID, _):
          return eventConnectionID == connectionID
        default:
          return false
        }
      },
      "An unsupported move must not copy, delete, or expunge source messages."
    )
  }

  private func assertReducedCapabilityMoveMapping(
    _ mapping: MailEngineUIDMapping,
    inbox: MailEngineMailboxIdentity,
    archive: MailEngineMailboxIdentity
  ) {
    XCTAssertEqual(mapping.sourceMailbox, inbox)
    XCTAssertEqual(mapping.sourceUIDValidity, 44)
    XCTAssertEqual(mapping.destinationMailbox, archive)
    XCTAssertEqual(mapping.destinationUIDValidity, 92)
    XCTAssertEqual(
      Dictionary(uniqueKeysWithValues: mapping.pairs.map { ($0.sourceUID, $0.destinationUID) }),
      [
        9: 209,
        8: 208,
      ]
    )
  }

  func verifyMetadataAndBodyParts() async throws {
    let session = try await connect(fixture: .successful).session
    let inbox = MailEngineMailboxIdentity("INBOX")
    let firstPage = try await session.loadMetadataPage(
      mailbox: inbox,
      beforeUID: nil,
      limit: 2
    )
    let historicalPage = try await session.loadMetadataPage(
      mailbox: inbox,
      beforeUID: firstPage.nextOlderUID,
      limit: 2
    )

    XCTAssertEqual(
      firstPage.messages,
      expectedMetadata(mailbox: inbox, uidValidity: 44, uids: [9, 8])
    )
    XCTAssertEqual(
      historicalPage.messages,
      expectedMetadata(mailbox: inbox, uidValidity: 44, uids: [7])
    )
    assertMetadataPagination(firstPage: firstPage, historicalPage: historicalPage)
    await assertMetadataPageRequests(mailbox: inbox)

    let requestedParts = requestedBodyPartSelectors
    let parts = try await session.fetchBodyParts(
      requestedParts,
      for: firstPage.messages[0].identity
    )
    assertBodyParts(parts, uid: 9, selectors: requestedParts)
    let secondMessageParts = try await session.fetchBodyParts(
      requestedParts,
      for: firstPage.messages[1].identity
    )
    assertBodyParts(secondMessageParts, uid: 8, selectors: requestedParts)
    await assertBodyPartRequests(
      messages: Array(firstPage.messages.prefix(2)),
      selectors: requestedParts
    )
    try await verifyInvalidMetadataIdentifiers(mailbox: inbox)
    try await verifyCrossAccountIdentityRejection(mailbox: inbox)
  }

  // swiftlint:disable:next function_body_length
  private func verifyCrossAccountIdentityRejection(
    mailbox: MailEngineMailboxIdentity
  ) async throws {
    let first = try await connect(
      fixture: .successful,
      connectionID: "identity-connection-one"
    ).session
    let second = try await connect(
      fixture: .successful,
      connectionID: "identity-connection-two"
    ).session
    let firstMessage = try await first.loadMetadataPage(
      mailbox: mailbox,
      beforeUID: nil,
      limit: 1
    ).messages[0].identity
    let secondMessage = try await second.loadMetadataPage(
      mailbox: mailbox,
      beforeUID: nil,
      limit: 1
    ).messages[0].identity
    XCTAssertNotEqual(firstMessage, secondMessage)
    let requestsBefore = await factory.events().filter {
      if case .bodyPartsRequested(connectionID: "identity-connection-two", _, _) = $0 {
        return true
      }
      return false
    }.count
    do {
      _ = try await second.fetchBodyParts(
        [MailEngineBodyPartSelector("1.TEXT")],
        for: firstMessage
      )
      XCTFail("A message identity from another connection must be rejected.")
    } catch {
      XCTAssertEqual(error as? MailEngineError, .staleMessageIdentity)
    }
    let requestsAfter = await factory.events().filter {
      if case .bodyPartsRequested(connectionID: "identity-connection-two", _, _) = $0 {
        return true
      }
      return false
    }.count
    XCTAssertEqual(
      requestsAfter,
      requestsBefore,
      "A cross-account identity must be rejected before reaching IMAP."
    )
    let mutationRequestsBefore = await mutationEvents(
      connectionID: "identity-connection-two"
    ).count
    for operation in ["copy", "move"] {
      do {
        if operation == "copy" {
          _ = try await second.copy(
            messages: [firstMessage],
            to: MailEngineMailboxIdentity("Archive")
          )
        } else {
          _ = try await second.move(
            messages: [firstMessage],
            to: MailEngineMailboxIdentity("Archive")
          )
        }
        XCTFail("A mutation identity from another connection must be rejected.")
      } catch {
        XCTAssertEqual(error as? MailEngineError, .staleMessageIdentity)
      }
    }
    let mutationRequestsAfter = await mutationEvents(
      connectionID: "identity-connection-two"
    ).count
    XCTAssertEqual(
      mutationRequestsAfter,
      mutationRequestsBefore,
      "A cross-account mutation identity must be rejected before reaching IMAP."
    )
  }

  private func verifyInvalidMetadataIdentifiers(
    mailbox: MailEngineMailboxIdentity
  ) async throws {
    for invalidUID in [Int64(-1), 0, 4_294_967_296] {
      let session = try await connect(fixture: .invalidMetadataUID(uid: invalidUID)).session
      do {
        _ = try await session.loadMetadataPage(mailbox: mailbox, beforeUID: nil, limit: 2)
        XCTFail("Metadata UID \(invalidUID) must be rejected.")
      } catch {
        XCTAssertEqual(error as? MailEngineUIDMappingError, .invalidUID)
      }
    }
    for invalidUIDValidity in [Int64(-1), 0, 4_294_967_296] {
      for fixture in [
        MailEngineQualificationFixture.invalidMetadataPageUIDValidity(
          uidValidity: invalidUIDValidity
        ),
        .invalidMetadataMessageUIDValidity(uidValidity: invalidUIDValidity),
      ] {
        let session = try await connect(fixture: fixture).session
        do {
          _ = try await session.loadMetadataPage(mailbox: mailbox, beforeUID: nil, limit: 2)
          XCTFail("Metadata UIDVALIDITY \(invalidUIDValidity) must be rejected.")
        } catch {
          XCTAssertEqual(error as? MailEngineUIDMappingError, .invalidSourceUIDValidity)
        }
      }
    }
    let mismatchedSession = try await connect(
      fixture: .mismatchedMetadataUIDValidity
    ).session
    do {
      _ = try await mismatchedSession.loadMetadataPage(
        mailbox: mailbox,
        beforeUID: nil,
        limit: 1
      )
      XCTFail("Metadata identities must match their page UIDVALIDITY.")
    } catch {
      XCTAssertEqual(error as? MailEngineUIDMappingError, .invalidSourceUIDValidity)
    }
    for invalidUID in [Int64(-1), 0, 4_294_967_296] {
      let session = try await connect(
        fixture: .invalidMetadataNextOlderUID(uid: invalidUID)
      ).session
      do {
        _ = try await session.loadMetadataPage(mailbox: mailbox, beforeUID: nil, limit: 1)
        XCTFail("Metadata pagination UID \(invalidUID) must be rejected.")
      } catch {
        XCTAssertEqual(error as? MailEngineUIDMappingError, .invalidUID)
      }
    }
  }

  private func assertBodyParts(
    _ parts: [MailEngineBodyPart],
    uid: Int64,
    selectors: Set<MailEngineBodyPartSelector>
  ) {
    XCTAssertEqual(Set(parts.map(\.selector)), selectors)
    XCTAssertEqual(parts.count, selectors.count)
    XCTAssertEqual(
      Dictionary(uniqueKeysWithValues: parts.map { ($0.selector, $0.data) }),
      [
        MailEngineBodyPartSelector("1.TEXT"): Data("INBOX-44-\(uid)-1.TEXT".utf8),
        MailEngineBodyPartSelector("2.MIME"): Data("INBOX-44-\(uid)-2.MIME".utf8),
      ]
    )
  }

  private func assertMetadataPageRequests(mailbox: MailEngineMailboxIdentity) async {
    let events = await factory.events()
    XCTAssertEqual(
      events.filter {
        if case .metadataPageRequested(connectionID: "connection-a", _, _, _) = $0 {
          return true
        }
        return false
      },
      [
        .metadataPageRequested(
          connectionID: "connection-a",
          mailbox: mailbox,
          beforeUID: nil,
          limit: 2
        ),
        .metadataPageRequested(
          connectionID: "connection-a",
          mailbox: mailbox,
          beforeUID: 8,
          limit: 2
        ),
      ]
    )
  }

  private func assertBodyPartRequests(
    messages: [MailEngineMessageMetadata],
    selectors: Set<MailEngineBodyPartSelector>
  ) async {
    let events = await factory.events()
    XCTAssertEqual(
      events.compactMap { event -> MailEngineQualificationEvent? in
        if case .bodyPartsRequested(connectionID: "connection-a", _, _) = event {
          return event
        }
        return nil
      },
      messages.map { message in
        .bodyPartsRequested(
          connectionID: "connection-a",
          message: message.identity,
          selectors: selectors
        )
      }
    )
  }

  private var requestedBodyPartSelectors: Set<MailEngineBodyPartSelector> {
    [
      MailEngineBodyPartSelector("1.TEXT"),
      MailEngineBodyPartSelector("2.MIME"),
    ]
  }

  private func messageIdentity(
    _ connectionID: String,
    _ mailbox: MailEngineMailboxIdentity,
    _ uid: Int64,
    _ uidValidity: Int64 = 44
  ) -> MailEngineMessageIdentity {
    MailEngineMessageIdentity(
      connectionID: connectionID,
      mailbox: mailbox,
      uid: uid,
      uidValidity: uidValidity
    )
  }

  private func messageIdentities(
    connectionID: String,
    mailbox: MailEngineMailboxIdentity,
    uidValidity: Int64,
    uids: [Int64]
  ) -> [MailEngineMessageIdentity] {
    uids.map { messageIdentity(connectionID, mailbox, $0, uidValidity) }
  }

  private func assertMetadataPagination(
    firstPage: MailEngineMetadataPage,
    historicalPage: MailEngineMetadataPage
  ) {
    XCTAssertEqual(firstPage.uidValidity, 44)
    XCTAssertEqual(firstPage.nextOlderUID, 8)
    XCTAssertEqual(historicalPage.uidValidity, 44)
    XCTAssertNil(historicalPage.nextOlderUID)
  }

  private func expectedMetadata(
    mailbox: MailEngineMailboxIdentity,
    uidValidity: Int64,
    uids: [Int64]
  ) -> [MailEngineMessageMetadata] {
    uids.map { uid in
      let flags: Set<String> =
        switch uid {
        case 9:
          ["\\Seen"]
        case 8:
          ["\\Flagged"]
        default:
          ["\\Answered"]
        }
      return MailEngineMessageMetadata(
        flags: flags,
        identity: messageIdentity("connection-a", mailbox, uid, uidValidity),
        internalDate: Date(timeIntervalSince1970: TimeInterval(uid)),
        rfcMessageID: "<\(uid)@example.com>"
      )
    }
  }

  func verifyIDLEAndConnectionIsolation() async throws {
    try await verifyIDLERecovery()
    try await verifySuccessfulTLS12IDLERecovery()
    try await verifyXOAUTH2IDLERecovery()
    try await verifyIDLERecoveryAuthenticationRejection()
    try await verifyIDLERecoveryTLSFloor()
    try await verifyIDLERecoveryServerIdentityValidation()
    try await verifyInvalidIDLEEvents()
    try await verifyOverlappingConnectionSetup()
    try await verifyOverlappingConnectionIsolation()
  }

  private func verifyIDLERecovery() async throws {
    let connectionID = "idle-recovery-success"
    let recoveringSession = try await connect(
      fixture: successfulIDLERecoveryFixture,
      connectionID: connectionID
    ).session
    let inbox = MailEngineMailboxIdentity("INBOX")
    let closesBeforeDisconnect = countIMAPCloses(
      await factory.events(),
      connectionID: connectionID
    )
    do {
      try await recoveringSession.idle(mailbox: inbox) { _ in }
      XCTFail("The first IDLE attempt should disconnect.")
    } catch {
      XCTAssertEqual(error as? MailEngineError, .connectionClosed)
    }
    await assertIMAPCloseCount(connectionID, expected: closesBeforeDisconnect + 1)
    let eventCountBeforeRecovery = await factory.events().count
    let recoveredEvents = LockedBox<[MailEngineIdleEvent]>([])
    let handshakeAtCallback = LockedBox<[MailEngineQualificationEvent]>([])
    let recoveryTask = Task {
      try await recoveringSession.idle(mailbox: inbox) { event in
        let events = await factory.events()
        handshakeAtCallback.withValue {
          $0 = Array(events.dropFirst(eventCountBeforeRecovery)).filter {
            isRecoveredIDLEHandshakeEvent($0, connectionID: connectionID, mailbox: inbox)
          }
        }
        recoveredEvents.withValue { $0.append(event) }
      }
    }
    try await assertSuccessfulRecoveredIDLE(
      callbacks: recoveredEvents,
      handshake: handshakeAtCallback,
      connectionID: connectionID,
      mailbox: inbox
    )
    try await finishRecoveredIDLEVerification(
      recoveryTask,
      session: recoveringSession,
      callbacks: recoveredEvents,
      connectionID: connectionID,
      inbox: inbox
    )
  }

  private func finishRecoveredIDLEVerification(
    _ task: Task<Void, Error>,
    session: any MailEngineSession,
    callbacks: LockedBox<[MailEngineIdleEvent]>,
    connectionID: String,
    inbox: MailEngineMailboxIdentity
  ) async throws {
    await assertRecoveredIDLECancellation(
      task,
      callbacks: callbacks,
      connectionID: connectionID
    )
    try await verifyRecoveredIDLECancellation(
      session,
      connectionID: connectionID,
      inbox: inbox
    )
    try await verifyRecoveredIDLEPreservesSMTP(session, connectionID: connectionID)
  }

  private var successfulIDLERecoveryFixture: MailEngineQualificationFixture {
    .idleDisconnectThenRecover(
      maximumReconnectTLSVersion: nil,
      requiresXOAUTH2Challenge: false
    )
  }

  private func assertRecoveredIDLECancellation(
    _ task: Task<Void, Error>,
    callbacks: LockedBox<[MailEngineIdleEvent]>,
    connectionID: String
  ) async {
    let callbacksBeforeCancellation = callbacks.value
    await assertIdleCancellation(
      task,
      failureMessage: "Recovered IDLE must remain active until cancelled."
    )
    await assertNoDelayedCallbacks(
      callbacks,
      after: callbacksBeforeCancellation,
      connectionID: connectionID,
      failureMessage: "A cancelled recovered IDLE must not deliver a delayed callback."
    )
  }

  private func verifyRecoveredIDLECancellation(
    _ session: any MailEngineSession,
    connectionID: String,
    inbox: MailEngineMailboxIdentity
  ) async throws {
    let events = await factory.events()
    XCTAssertTrue(
      events.contains(.idleCancelled(connectionID: connectionID)),
      "Cancelling recovered IDLE must cancel its owning server command."
    )
    try await verifyRecoveredIDLEPreservesIMAP(
      session,
      connectionID: connectionID,
      inbox: inbox
    )
  }

  private func verifyRecoveredIDLEPreservesSMTP(
    _ session: any MailEngineSession,
    connectionID: String
  ) async throws {
    try await assertSMTPSessionRemainsUsable(
      session,
      connectionID: connectionID,
      preservationReason: "Recovering IMAP IDLE must preserve the account's SMTP transport.",
      allowPriorIMAPClose: true
    )
  }

  private func verifyRecoveredIDLEPreservesIMAP(
    _ session: any MailEngineSession,
    connectionID: String,
    inbox: MailEngineMailboxIdentity
  ) async throws {
    let requestsBefore = await factory.events().filter {
      if case .metadataPageRequested(let eventConnectionID, _, _, _) = $0 {
        return eventConnectionID == connectionID
      }
      return false
    }
    let page = try await session.loadMetadataPage(mailbox: inbox, beforeUID: nil, limit: 1)
    XCTAssertEqual(page.messages.map(\.identity.uid), [9])
    let requestsAfter = await factory.events().filter {
      if case .metadataPageRequested(let eventConnectionID, _, _, _) = $0 {
        return eventConnectionID == connectionID
      }
      return false
    }
    XCTAssertEqual(
      requestsAfter,
      requestsBefore + [
        .metadataPageRequested(
          connectionID: connectionID,
          mailbox: inbox,
          beforeUID: nil,
          limit: 1
        )
      ],
      "Recovered IDLE cancellation must preserve follow-up IMAP work on the same session."
    )
  }

  private func verifyInvalidIDLEEvents() async throws {
    let inbox = MailEngineMailboxIdentity("INBOX")
    for invalidUID in [Int64(-1), 0, 4_294_967_296] {
      let callbacks = LockedBox<[MailEngineIdleEvent]>([])
      let session = try await connect(fixture: .invalidIdleChangedUID(uid: invalidUID)).session
      do {
        try await session.idle(mailbox: inbox) { event in
          callbacks.withValue { $0.append(event) }
        }
        XCTFail("IDLE changed UID \(invalidUID) must be rejected.")
      } catch {
        XCTAssertEqual(error as? MailEngineUIDMappingError, .invalidUID)
      }
      XCTAssertEqual(callbacks.value, [])
    }
    for invalidUIDValidity in [Int64(-1), 0, 4_294_967_296] {
      let callbacks = LockedBox<[MailEngineIdleEvent]>([])
      let session = try await connect(
        fixture: .invalidIdleResetUIDValidity(uidValidity: invalidUIDValidity)
      ).session
      do {
        try await session.idle(mailbox: inbox) { event in
          callbacks.withValue { $0.append(event) }
        }
        XCTFail("IDLE reset UIDVALIDITY \(invalidUIDValidity) must be rejected.")
      } catch {
        XCTAssertEqual(error as? MailEngineUIDMappingError, .invalidSourceUIDValidity)
      }
      XCTAssertEqual(callbacks.value, [])
    }
  }

  private func verifyOverlappingConnectionSetup() async throws {
    async let firstConnection = connect(
      fixture: .overlappingConnectionSetup,
      authorization: .password(username: "first@example.com", password: "first-password"),
      connectionID: "setup-connection-one"
    )
    async let secondConnection = connect(
      fixture: .overlappingConnectionSetup,
      authorization: .xoauth2(username: "second@example.com", accessToken: "second-token"),
      connectionID: "setup-connection-two"
    )
    let (first, second) = try await (firstConnection, secondConnection)
    assertOverlappingSetupSnapshots(first.snapshot, second.snapshot)
    try await assertOverlappingSetupMetadata(first.session, second.session)
    try await assertOverlappingSetupSMTPIsolation(first.session, second.session)
    for (connectionID, authorizationEvent) in [
      (
        "setup-connection-one",
        MailEngineQualificationEvent.authenticationStarted(
          connectionID: "setup-connection-one",
          service: .imap
        )
      ),
      (
        "setup-connection-two",
        MailEngineQualificationEvent.authenticationStarted(
          connectionID: "setup-connection-two",
          service: .imap
        )
      ),
    ] {
      let events = await factory.events()
      XCTAssertEqual(
        events.filter { $0 == authorizationEvent }.count,
        1,
        "Overlapping setup must keep \(connectionID) authentication connection-scoped."
      )
    }
  }

  private func assertOverlappingSetupMetadata(
    _ first: any MailEngineSession,
    _ second: any MailEngineSession
  ) async throws {
    let inbox = MailEngineMailboxIdentity("INBOX")
    async let firstPage = first.loadMetadataPage(mailbox: inbox, beforeUID: nil, limit: 1)
    async let secondPage = second.loadMetadataPage(mailbox: inbox, beforeUID: nil, limit: 1)
    let (firstResult, secondResult) = try await (firstPage, secondPage)
    XCTAssertEqual(
      firstResult,
      overlappingMetadataPage(
        connectionID: "setup-connection-one",
        mailbox: inbox,
        uid: 19
      )
    )
    XCTAssertEqual(
      secondResult,
      overlappingMetadataPage(
        connectionID: "setup-connection-two",
        mailbox: inbox,
        uid: 29
      )
    )
  }

  private func assertOverlappingSetupSnapshots(
    _ first: MailEngineConnectionSnapshot,
    _ second: MailEngineConnectionSnapshot
  ) {
    XCTAssertEqual(first.capabilities, [.idle, .specialUse, .uidPlus])
    XCTAssertEqual(second.capabilities, [.idle, .move, .specialUse, .uidPlus])
    XCTAssertEqual(
      Dictionary(uniqueKeysWithValues: first.mailboxes.map { ($0.identity, $0.specialUses) }),
      [
        MailEngineMailboxIdentity("INBOX"): [],
        MailEngineMailboxIdentity("First Sent"): [.sent],
      ]
    )
    XCTAssertEqual(
      Dictionary(uniqueKeysWithValues: second.mailboxes.map { ($0.identity, $0.specialUses) }),
      [
        MailEngineMailboxIdentity("INBOX"): [],
        MailEngineMailboxIdentity("Second Sent"): [.sent],
      ]
    )
    XCTAssertEqual(first.transportSecurity, [.imap: .tls12, .smtp: .tls12])
    XCTAssertEqual(second.transportSecurity, [.imap: .tls13, .smtp: .tls13])
  }

  private func assertOverlappingSetupSMTPIsolation(
    _ first: any MailEngineSession,
    _ second: any MailEngineSession
  ) async throws {
    let firstEnvelope = MailEngineEnvelope(
      recipients: ["first-recipient@example.com"],
      sender: "first-sender@example.com"
    )
    let secondEnvelope = MailEngineEnvelope(
      recipients: ["second-recipient@example.com"],
      sender: "second-sender@example.com"
    )
    let firstMessage = Data("Subject: First setup session\r\n\r\nFirst".utf8)
    let secondMessage = Data("Subject: Second setup session\r\n\r\nSecond".utf8)
    async let firstOutcome = first.submit(envelope: firstEnvelope, rawMessage: firstMessage)
    async let secondOutcome = second.submit(envelope: secondEnvelope, rawMessage: secondMessage)
    let outcomes = try await (firstOutcome, secondOutcome)
    XCTAssertEqual(outcomes.0, .accepted(serverMessageID: "setup-smtp-message-1"))
    XCTAssertEqual(outcomes.1, .accepted(serverMessageID: "setup-smtp-message-2"))
    let events = await factory.events().filter {
      if case .submissionReceived(let connectionID, _, _) = $0 {
        return connectionID == "setup-connection-one" || connectionID == "setup-connection-two"
      }
      return false
    }
    assertExactlyOnce(
      events,
      events:
        .submissionReceived(
          connectionID: "setup-connection-one",
          envelope: firstEnvelope,
          rawMessage: firstMessage
        ),
      .submissionReceived(
        connectionID: "setup-connection-two",
        envelope: secondEnvelope,
        rawMessage: secondMessage
      )
    )
  }

  private func assertSuccessfulIDLERecoveryHandshake(
    _ events: [MailEngineQualificationEvent],
    connectionID: String,
    mailbox: MailEngineMailboxIdentity,
    expectsXOAUTH2Challenge: Bool = false
  ) {
    guard
      case .tlsEstablished(
        connectionID: connectionID,
        service: .imap,
        version: let negotiatedVersion
      ) = events.first
    else {
      XCTFail("Recovered IDLE must establish secure transport before callback delivery.")
      return
    }
    XCTAssertGreaterThanOrEqual(negotiatedVersion, .tls12)
    var expectedAuthenticationEvents = [
      MailEngineQualificationEvent.authenticationStarted(
        connectionID: connectionID,
        service: .imap
      )
    ]
    if expectsXOAUTH2Challenge {
      expectedAuthenticationEvents.append(
        .authenticationChallengeAnswered(connectionID: connectionID, service: .imap)
      )
    }
    expectedAuthenticationEvents.append(
      .authenticated(connectionID: connectionID, service: .imap)
    )
    expectedAuthenticationEvents.append(
      .idleStarted(connectionID: connectionID, mailbox: mailbox)
    )
    XCTAssertEqual(Array(events.dropFirst()), expectedAuthenticationEvents)
  }

  private func verifyIDLERecoveryTLSFloor() async throws {
    for transportMode in [MailEngineTransportMode.implicitTLS, .startTLS] {
      for legacyVersion in [MailEngineTLSVersion.tls10, .tls11] {
        try await verifyRejectedIDLERecovery(
          transportMode: transportMode,
          fixture: .idleDisconnectThenRecover(
            maximumReconnectTLSVersion: legacyVersion,
            requiresXOAUTH2Challenge: false
          ),
          expectedError: .tlsVersionUnsupported,
          connectionID: "idle-reconnect-\(transportMode)-\(legacyVersion)"
        )
      }
      try await verifyRejectedIDLERecovery(
        transportMode: transportMode,
        fixture: .idleDisconnectThenRecover(
          maximumReconnectTLSVersion: .tls12,
          requiresXOAUTH2Challenge: false
        ),
        expectedError: .tlsVersionUnsupported,
        connectionID: "idle-reconnect-tls13-floor-\(transportMode)",
        minimumTLSVersion: .tls13
      )
    }
    try await verifyRejectedIDLERecovery(
      transportMode: .startTLS,
      fixture: .idleDisconnectThenRejectRecovery(error: .startTLSRejected),
      expectedError: .startTLSRejected,
      connectionID: "idle-reconnect-starttls-upgrade-rejected"
    )
    try await verifyRejectedIDLERecovery(
      transportMode: .startTLS,
      fixture: .idleDisconnectThenUnsecuredSTARTTLS,
      expectedError: .startTLSRejected,
      connectionID: "idle-reconnect-starttls-acknowledged-without-upgrade"
    )
  }

  private func verifyIDLERecoveryServerIdentityValidation() async throws {
    for transportMode in [MailEngineTransportMode.implicitTLS, .startTLS] {
      for error in [MailEngineError.certificateRejected, .serverIdentityMismatch] {
        try await verifyRejectedIDLERecovery(
          transportMode: transportMode,
          fixture: .idleDisconnectThenRejectRecovery(error: error),
          expectedError: error,
          connectionID: "idle-reconnect-\(transportMode)-\(error)"
        )
      }
    }
  }

  private func verifyIDLERecoveryAuthenticationRejection() async throws {
    for (authorization, requiresXOAUTH2Challenge) in [
      (
        MailEngineAuthorization.password(
          username: "idle-recovery-password@example.com",
          password: "rejected-password"
        ),
        false
      ),
      (
        .xoauth2(
          username: "idle-recovery-xoauth2@example.com",
          accessToken: "rejected-token"
        ),
        true
      ),
    ] {
      for transportMode in [MailEngineTransportMode.implicitTLS, .startTLS] {
        let connectionID =
          "idle-reconnect-auth-rejected-\(requiresXOAUTH2Challenge)-\(transportMode)"
        let eventsBeforeRecovery = try await prepareRejectedAuthenticationRecovery(
          authorization: authorization,
          requiresXOAUTH2Challenge: requiresXOAUTH2Challenge,
          transportMode: transportMode,
          connectionID: connectionID
        )
        assertRejectedAuthenticationRecovery(
          Array((await factory.events()).dropFirst(eventsBeforeRecovery)),
          connectionID: connectionID,
          expectsXOAUTH2Challenge: requiresXOAUTH2Challenge
        )
      }
    }
  }

  private func prepareRejectedAuthenticationRecovery(
    authorization: MailEngineAuthorization,
    requiresXOAUTH2Challenge: Bool,
    transportMode: MailEngineTransportMode,
    connectionID: String
  ) async throws -> Int {
    let inbox = MailEngineMailboxIdentity("INBOX")
    let session = try await connect(
      fixture: .idleDisconnectThenRejectAuthentication(
        requiresXOAUTH2Challenge: requiresXOAUTH2Challenge
      ),
      authorization: authorization,
      connectionID: connectionID,
      imapTransportMode: transportMode
    ).session
    await assertInitialIDLEDisconnect(
      session,
      connectionID: connectionID,
      mailbox: inbox,
      failureMessage: "The first authentication-rejection IDLE attempt should disconnect."
    )
    let eventCount = await factory.events().count
    let callbacks = LockedBox<[MailEngineIdleEvent]>([])
    do {
      try await session.idle(mailbox: inbox) { event in
        callbacks.withValue { $0.append(event) }
      }
      XCTFail("Rejected recovery authentication must fail IDLE.")
    } catch {
      XCTAssertEqual(error as? MailEngineError, .authenticationRejected)
    }
    await assertNoDelayedCallbacks(
      callbacks,
      after: [],
      connectionID: connectionID,
      failureMessage: "Rejected recovery authentication must not deliver a late callback."
    )
    return eventCount
  }

  private func assertRejectedAuthenticationRecovery(
    _ events: [MailEngineQualificationEvent],
    connectionID: String,
    expectsXOAUTH2Challenge: Bool
  ) {
    let events = events.filter {
      if case .idleLateCallbackAttempted = $0 { return false }
      return true
    }
    guard
      case .tlsEstablished(
        connectionID: connectionID,
        service: .imap,
        version: let negotiatedVersion
      ) = events.first
    else {
      XCTFail("Recovery must establish secure transport before authentication rejection.")
      return
    }
    XCTAssertGreaterThanOrEqual(negotiatedVersion, .tls12)
    var expected = [
      MailEngineQualificationEvent.authenticationStarted(
        connectionID: connectionID,
        service: .imap
      )
    ]
    if expectsXOAUTH2Challenge {
      expected.append(
        .authenticationChallengeAnswered(connectionID: connectionID, service: .imap)
      )
    }
    expected.append(.serviceClosed(connectionID: connectionID, service: .imap))
    XCTAssertEqual(Array(events.dropFirst()), expected)
  }

  private func verifySuccessfulTLS12IDLERecovery() async throws {
    for transportMode in [MailEngineTransportMode.implicitTLS, .startTLS] {
      try await verifySuccessfulTLS12IDLERecovery(transportMode: transportMode)
    }
  }

  private func verifySuccessfulTLS12IDLERecovery(
    transportMode: MailEngineTransportMode
  ) async throws {
    let connectionID = "idle-reconnect-tls12-\(transportMode)"
    let inbox = MailEngineMailboxIdentity("INBOX")
    let session = try await connect(
      fixture: .idleDisconnectThenRecover(
        maximumReconnectTLSVersion: .tls12,
        requiresXOAUTH2Challenge: false
      ),
      connectionID: connectionID,
      imapTransportMode: transportMode
    ).session
    let closesBeforeDisconnect = countIMAPCloses(
      await factory.events(),
      connectionID: connectionID
    )
    do {
      try await session.idle(mailbox: inbox) { _ in }
      XCTFail("The first TLS 1.2 IDLE attempt should disconnect.")
    } catch {
      XCTAssertEqual(error as? MailEngineError, .connectionClosed)
    }
    await assertIMAPCloseCount(connectionID, expected: closesBeforeDisconnect + 1)
    let eventCountBeforeRecovery = await factory.events().count
    let callbacks = LockedBox<[MailEngineIdleEvent]>([])
    let handshakeAtCallback = LockedBox<[MailEngineQualificationEvent]>([])
    let recoveryTask = Task {
      try await session.idle(mailbox: inbox) { event in
        let events = await factory.events()
        handshakeAtCallback.withValue {
          $0 = Array(events.dropFirst(eventCountBeforeRecovery)).filter {
            isRecoveredIDLEHandshakeEvent($0, connectionID: connectionID, mailbox: inbox)
          }
        }
        callbacks.withValue { $0.append(event) }
      }
    }
    try await assertSuccessfulRecoveredIDLE(
      callbacks: callbacks,
      handshake: handshakeAtCallback,
      connectionID: connectionID,
      mailbox: inbox
    )
    await assertRecoveredIDLECancellation(
      recoveryTask,
      callbacks: callbacks,
      connectionID: connectionID
    )
    try await verifyRecoveredIDLECancellation(session, connectionID: connectionID, inbox: inbox)
    try await verifyRecoveredIDLEPreservesSMTP(session, connectionID: connectionID)
  }

  private func verifyXOAUTH2IDLERecovery() async throws {
    for transportMode in [MailEngineTransportMode.implicitTLS, .startTLS] {
      try await verifyXOAUTH2IDLERecovery(transportMode: transportMode)
    }
  }

  private func verifyXOAUTH2IDLERecovery(
    transportMode: MailEngineTransportMode
  ) async throws {
    let connectionID = "idle-reconnect-xoauth2-\(transportMode)"
    let inbox = MailEngineMailboxIdentity("INBOX")
    let session = try await connect(
      fixture: .idleDisconnectThenRecover(
        maximumReconnectTLSVersion: .tls12,
        requiresXOAUTH2Challenge: true
      ),
      authorization: .xoauth2(
        username: "idle-recovery@example.com",
        accessToken: "idle-recovery-token"
      ),
      connectionID: connectionID,
      imapTransportMode: transportMode
    ).session
    await assertInitialIDLEDisconnect(
      session,
      connectionID: connectionID,
      mailbox: inbox,
      failureMessage: "The first XOAUTH2 IDLE attempt should disconnect."
    )
    let eventCountBeforeRecovery = await factory.events().count
    let callbacks = LockedBox<[MailEngineIdleEvent]>([])
    let handshakeAtCallback = LockedBox<[MailEngineQualificationEvent]>([])
    let recoveryTask = Task {
      try await session.idle(mailbox: inbox) { event in
        let events = await factory.events()
        handshakeAtCallback.withValue {
          $0 = Array(events.dropFirst(eventCountBeforeRecovery)).filter {
            isRecoveredIDLEHandshakeEvent($0, connectionID: connectionID, mailbox: inbox)
          }
        }
        callbacks.withValue { $0.append(event) }
      }
    }
    try await assertSuccessfulRecoveredIDLE(
      callbacks: callbacks,
      handshake: handshakeAtCallback,
      connectionID: connectionID,
      mailbox: inbox,
      expectsXOAUTH2Challenge: true
    )
    try await finishRecoveredIDLEVerification(
      recoveryTask,
      session: session,
      callbacks: callbacks,
      connectionID: connectionID,
      inbox: inbox
    )
  }

  private func assertInitialIDLEDisconnect(
    _ session: any MailEngineSession,
    connectionID: String,
    mailbox: MailEngineMailboxIdentity,
    failureMessage: String
  ) async {
    let closesBeforeDisconnect = countIMAPCloses(
      await factory.events(),
      connectionID: connectionID
    )
    do {
      try await session.idle(mailbox: mailbox) { _ in }
      XCTFail(failureMessage)
    } catch {
      XCTAssertEqual(error as? MailEngineError, .connectionClosed)
    }
    await assertIMAPCloseCount(connectionID, expected: closesBeforeDisconnect + 1)
  }

  private func assertSuccessfulRecoveredIDLE(
    callbacks: LockedBox<[MailEngineIdleEvent]>,
    handshake: LockedBox<[MailEngineQualificationEvent]>,
    connectionID: String,
    mailbox: MailEngineMailboxIdentity,
    expectsXOAUTH2Challenge: Bool = false
  ) async throws {
    try await waitForIdleEvents(callbacks, count: 1, timeout: .seconds(2))
    XCTAssertEqual(callbacks.value, [.changedUIDs([10])])
    await assertRecoveredIDLEMailbox(connectionID: connectionID, mailbox: mailbox)
    assertSuccessfulIDLERecoveryHandshake(
      handshake.value,
      connectionID: connectionID,
      mailbox: mailbox,
      expectsXOAUTH2Challenge: expectsXOAUTH2Challenge
    )
  }

  private func isRecoveredIDLEHandshakeEvent(
    _ event: MailEngineQualificationEvent,
    connectionID: String,
    mailbox: MailEngineMailboxIdentity
  ) -> Bool {
    event.belongs(to: connectionID, service: .imap)
      || event == .idleStarted(connectionID: connectionID, mailbox: mailbox)
  }

  private func assertRecoveredIDLEMailbox(
    connectionID: String,
    mailbox: MailEngineMailboxIdentity
  ) async {
    let idleStarts = await factory.events().filter {
      $0 == .idleStarted(connectionID: connectionID, mailbox: mailbox)
    }
    XCTAssertEqual(
      idleStarts.count,
      2,
      "Initial and recovered IDLE must each target the requested mailbox exactly once."
    )
  }

  // swiftlint:disable:next function_body_length
  private func verifyRejectedIDLERecovery(
    transportMode: MailEngineTransportMode,
    fixture: MailEngineQualificationFixture,
    expectedError: MailEngineError,
    connectionID: String,
    minimumTLSVersion: MailEngineTLSVersion = .tls12
  ) async throws {
    let callbacks = LockedBox<[MailEngineIdleEvent]>([])
    let session = try await connect(
      fixture: fixture,
      connectionID: connectionID,
      imapTransportMode: transportMode,
      minimumTLSVersion: minimumTLSVersion
    ).session
    let closesBeforeFirstAttempt = countIMAPCloses(
      await factory.events(),
      connectionID: connectionID
    )
    do {
      try await session.idle(mailbox: MailEngineMailboxIdentity("INBOX")) { _ in }
      XCTFail("The first IDLE attempt should disconnect.")
    } catch {
      XCTAssertEqual(error as? MailEngineError, .connectionClosed)
    }
    let eventsBeforeRecovery = await factory.events()
    let authenticationAttemptsBeforeRecovery = countIMAPAuthenticationStarts(
      eventsBeforeRecovery,
      connectionID: connectionID
    )
    let closesBeforeRecovery = countIMAPCloses(
      eventsBeforeRecovery,
      connectionID: connectionID
    )
    XCTAssertEqual(
      closesBeforeRecovery,
      closesBeforeFirstAttempt + 1,
      "The disconnected initial IDLE transport must be closed."
    )
    do {
      try await session.idle(mailbox: MailEngineMailboxIdentity("INBOX")) { event in
        callbacks.withValue { $0.append(event) }
      }
      XCTFail("An insecure IDLE recovery connection must be rejected.")
    } catch {
      XCTAssertEqual(error as? MailEngineError, expectedError)
    }
    await assertNoDelayedCallbacks(
      callbacks,
      after: [],
      connectionID: connectionID,
      failureMessage: "Rejected recovery transport must not deliver a late callback."
    )
    let recoveryEvents = await factory.events()
    XCTAssertEqual(
      countIMAPAuthenticationStarts(recoveryEvents, connectionID: connectionID),
      authenticationAttemptsBeforeRecovery
    )
    XCTAssertEqual(
      countIMAPCloses(recoveryEvents, connectionID: connectionID),
      closesBeforeRecovery + 1,
      "A rejected recovery transport must be closed."
    )
  }

  private func countIMAPAuthenticationStarts(
    _ events: [MailEngineQualificationEvent],
    connectionID: String
  ) -> Int {
    events.filter {
      $0 == .authenticationStarted(connectionID: connectionID, service: .imap)
    }.count
  }

  private func countIMAPCloses(
    _ events: [MailEngineQualificationEvent],
    connectionID: String
  ) -> Int {
    events.filter {
      $0 == .serviceClosed(connectionID: connectionID, service: .imap)
    }.count
  }

  private func assertIMAPCloseCount(_ connectionID: String, expected: Int) async {
    let closes = countIMAPCloses(await factory.events(), connectionID: connectionID)
    XCTAssertEqual(
      closes,
      expected,
      "A disconnected IDLE transport must be closed before recovery."
    )
  }

  private func verifyOverlappingConnectionIsolation() async throws {
    let inbox = MailEngineMailboxIdentity("INBOX")
    let secondIdleMailbox = MailEngineMailboxIdentity("Team Updates")
    let first = try await connect(
      fixture: .overlappingSMTP(serverMessageID: "smtp-message-1"),
      authorization: .password(username: "first@example.com", password: "first-password"),
      connectionID: "connection-one"
    ).session
    let second = try await connect(
      fixture: .overlappingSMTP(serverMessageID: "smtp-message-2"),
      authorization: .xoauth2(username: "second@example.com", accessToken: "second-token"),
      connectionID: "connection-two"
    ).session
    let firstCallbacks = LockedBox<[MailEngineIdleEvent]>([])
    let secondCallbacks = LockedBox<[MailEngineIdleEvent]>([])
    let firstTask = Task {
      try await first.idle(mailbox: inbox) { event in
        firstCallbacks.withValue { $0.append(event) }
      }
    }
    let secondTask = Task {
      try await second.idle(mailbox: secondIdleMailbox) { event in
        secondCallbacks.withValue { $0.append(event) }
      }
    }
    try await factory.waitForIdleStarts(4, timeout: .seconds(2))
    try await waitForIdleEvents(firstCallbacks, count: 1, timeout: .seconds(2))
    try await waitForIdleEvents(secondCallbacks, count: 1, timeout: .seconds(2))
    XCTAssertEqual(firstCallbacks.value, [.changedUIDs([19])])
    XCTAssertEqual(secondCallbacks.value, [.changedUIDs([29])])
    await assertIdleStarts(inbox: inbox, secondMailbox: secondIdleMailbox)
    try await verifyOverlappingSMTPIsolation(first: first, second: second)

    await assertFirstIdleCancellation(
      firstTask,
      secondTask: secondTask,
      firstCallbacks: firstCallbacks,
      secondCallbacks: secondCallbacks
    )
    try await verifyFirstCancelledIDLESession(first: first, second: second, inbox: inbox)

    try await verifySecondIdleCancellationPreservesSession(
      secondTask,
      preservedSession: first,
      session: second,
      callbacks: secondCallbacks
    )
    try await verifyNonIdleCancellationIsolation(inbox: inbox)
    try await verifyStateChangingOperationCancellationIsolation()
  }

  private func assertFirstIdleCancellation(
    _ firstTask: Task<Void, Error>,
    secondTask: Task<Void, Error>,
    firstCallbacks: LockedBox<[MailEngineIdleEvent]>,
    secondCallbacks: LockedBox<[MailEngineIdleEvent]>
  ) async {
    await assertIdleCancellation(
      firstTask, failureMessage: "Cancelling IDLE must report cancellation.")
    await assertOnlyFirstIdleCancelled()
    await assertNoDelayedCallbacks(first: firstCallbacks, second: secondCallbacks)
    await assertNoServiceClose(
      connectionID: "connection-two",
      failureMessage: "Cancelling one IDLE must not close the other account's transport."
    )
    await assertTaskStillPending(
      secondTask,
      failureMessage: "Cancelling the first IDLE must leave the second IDLE active."
    )
  }

  private func verifyFirstCancelledIDLESession(
    first: any MailEngineSession,
    second: any MailEngineSession,
    inbox: MailEngineMailboxIdentity
  ) async throws {
    try await verifyOverlappingMetadataIsolation(first: first, second: second, inbox: inbox)
    try await verifyCancelledIDLEPreservesSMTP(first, connectionID: "connection-one")
  }

  private func verifyCancelledIDLEPreservesSMTP(
    _ session: any MailEngineSession,
    connectionID: String
  ) async throws {
    try await assertSMTPSessionRemainsUsable(
      session,
      connectionID: connectionID,
      preservationReason: "Cancelling IDLE must preserve the owning session's SMTP transport.",
      expectedServerMessageID:
        connectionID == "connection-two" ? "smtp-message-2" : "smtp-message-1"
    )
  }

  private func verifySecondIdleCancellationPreservesSession(
    _ task: Task<Void, Error>,
    preservedSession: any MailEngineSession,
    session: any MailEngineSession,
    callbacks: LockedBox<[MailEngineIdleEvent]>
  ) async throws {
    let callbacksBeforeCancellation = callbacks.value
    await assertIdleCancellation(
      task,
      failureMessage: "Cancelling the second IDLE must report cancellation."
    )
    await assertSecondIdleCancelled()
    await assertNoDelayedCallbacks(
      callbacks,
      after: callbacksBeforeCancellation,
      connectionID: "connection-two",
      failureMessage: "The second cancelled IDLE must not deliver a delayed callback."
    )
    try await assertSessionRemainsUsable(session, connectionID: "connection-two")
    try await verifyCancelledIDLEPreservesSMTP(session, connectionID: "connection-two")
    try await assertSessionRemainsUsable(preservedSession, connectionID: "connection-one")
    try await verifyCancelledIDLEPreservesSMTP(
      preservedSession,
      connectionID: "connection-one"
    )
  }

  private func assertSecondIdleCancelled() async {
    let cancellations = await idleCancellationEvents()
    XCTAssertTrue(
      cancellations.contains(.idleCancelled(connectionID: "connection-two")),
      "Cancelling the second IDLE task must cancel its owning server command."
    )
  }

  private func assertOnlyFirstIdleCancelled() async {
    let cancellations = await idleCancellationEvents()
    XCTAssertTrue(cancellations.contains(.idleCancelled(connectionID: "connection-one")))
    XCTAssertFalse(cancellations.contains(.idleCancelled(connectionID: "connection-two")))
  }

  private func assertNoDelayedCallbacks(
    first: LockedBox<[MailEngineIdleEvent]>,
    second: LockedBox<[MailEngineIdleEvent]>
  ) async {
    let firstCountAtCancellation = first.value.count
    let secondCountAtCancellation = second.value.count
    do {
      try await factory.waitForIdleLateCallbackAttempt(
        connectionID: "connection-one",
        timeout: .seconds(2)
      )
    } catch {
      XCTFail("Timed out waiting for the first late-IDLE fixture event.")
      return
    }
    XCTAssertEqual(
      first.value.count,
      firstCountAtCancellation,
      "A cancelled IDLE must not deliver a delayed callback."
    )
    XCTAssertEqual(
      second.value.count,
      secondCountAtCancellation,
      "Cancelling another account's IDLE must not deliver a cross-session callback."
    )
  }

  private func assertNoDelayedCallbacks(
    _ callbacks: LockedBox<[MailEngineIdleEvent]>,
    after expected: [MailEngineIdleEvent],
    connectionID: String,
    failureMessage: String
  ) async {
    do {
      try await factory.waitForIdleLateCallbackAttempt(
        connectionID: connectionID,
        timeout: .seconds(2)
      )
    } catch {
      XCTFail("Timed out waiting for the \(connectionID) late-IDLE fixture event.")
      return
    }
    XCTAssertEqual(callbacks.value, expected, failureMessage)
  }

  private func assertNoServiceClose(
    connectionID: String,
    failureMessage: String
  ) async {
    let events = await factory.events()
    XCTAssertFalse(
      events.contains {
        if case .serviceClosed(let eventConnectionID, service: _) = $0 {
          return eventConnectionID == connectionID
        }
        return false
      },
      failureMessage
    )
  }

  private func assertNoSMTPServiceClose(
    connectionID: String,
    failureMessage: String
  ) async {
    let events = await factory.events()
    XCTAssertFalse(
      events.contains(.serviceClosed(connectionID: connectionID, service: .smtp)),
      failureMessage
    )
  }

  private func assertIdleStarts(
    inbox: MailEngineMailboxIdentity,
    secondMailbox: MailEngineMailboxIdentity
  ) async {
    let idleStarts = await factory.events().filter { event in
      if case .idleStarted(let connectionID, _) = event {
        return connectionID == "connection-one" || connectionID == "connection-two"
      }
      return false
    }
    let expectedStarts = [
      MailEngineQualificationEvent.idleStarted(
        connectionID: "connection-one",
        mailbox: inbox
      ),
      .idleStarted(connectionID: "connection-two", mailbox: secondMailbox),
    ]
    XCTAssertEqual(idleStarts.count, expectedStarts.count)
    for expectedStart in expectedStarts {
      XCTAssertEqual(
        idleStarts.filter { $0 == expectedStart }.count,
        1,
        "Each IDLE command must reach exactly once on its owning account transport."
      )
    }
  }

  private func verifyOverlappingMetadataIsolation(
    first: any MailEngineSession,
    second: any MailEngineSession,
    inbox: MailEngineMailboxIdentity
  ) async throws {
    async let firstPageResult = first.loadMetadataPage(
      mailbox: inbox,
      beforeUID: nil,
      limit: 1
    )
    async let secondPageResult = second.loadMetadataPage(
      mailbox: inbox,
      beforeUID: nil,
      limit: 1
    )
    let (firstPage, secondPage) = try await (firstPageResult, secondPageResult)
    XCTAssertEqual(
      firstPage,
      overlappingMetadataPage(connectionID: "connection-one", mailbox: inbox, uid: 19)
    )
    XCTAssertEqual(
      secondPage,
      overlappingMetadataPage(connectionID: "connection-two", mailbox: inbox, uid: 29)
    )
    let requests = await factory.events().filter { event in
      if case .metadataPageRequested(let connectionID, _, _, _) = event {
        return connectionID == "connection-one" || connectionID == "connection-two"
      }
      return false
    }
    assertExactlyOnce(
      requests,
      events:
        .metadataPageRequested(
          connectionID: "connection-one",
          mailbox: inbox,
          beforeUID: nil,
          limit: 1
        ),
      .metadataPageRequested(
        connectionID: "connection-two",
        mailbox: inbox,
        beforeUID: nil,
        limit: 1
      )
    )
  }

  private func overlappingMetadataPage(
    connectionID: String,
    mailbox: MailEngineMailboxIdentity,
    uid: Int64
  ) -> MailEngineMetadataPage {
    MailEngineMetadataPage(
      messages: [
        MailEngineMessageMetadata(
          flags: ["\\Seen"],
          identity: messageIdentity(connectionID, mailbox, uid, 44),
          internalDate: Date(timeIntervalSince1970: TimeInterval(uid)),
          rfcMessageID: "<\(uid)@example.com>"
        )
      ],
      nextOlderUID: uid,
      uidValidity: 44
    )
  }

  private func verifyOverlappingSMTPIsolation(
    first: any MailEngineSession,
    second: any MailEngineSession
  ) async throws {
    let firstEnvelope = MailEngineEnvelope(
      recipients: ["first-recipient@example.com"],
      sender: "first@example.com"
    )
    let secondEnvelope = MailEngineEnvelope(
      recipients: ["second-recipient@example.com"],
      sender: "second@example.com"
    )
    let firstMessage = Data("Subject: First account\r\n\r\nFirst body".utf8)
    let secondMessage = Data("Subject: Second account\r\n\r\nSecond body".utf8)
    async let firstOutcome = first.submit(
      envelope: firstEnvelope,
      rawMessage: firstMessage
    )
    async let secondOutcome = second.submit(
      envelope: secondEnvelope,
      rawMessage: secondMessage
    )
    let outcomes = try await (firstOutcome, secondOutcome)
    XCTAssertEqual(outcomes.0, .accepted(serverMessageID: "smtp-message-1"))
    XCTAssertEqual(outcomes.1, .accepted(serverMessageID: "smtp-message-2"))
    let submissionEvents = await factory.events().filter { event in
      if case .submissionReceived(let connectionID, _, _) = event {
        return connectionID == "connection-one" || connectionID == "connection-two"
      }
      return false
    }
    let firstEvent = MailEngineQualificationEvent.submissionReceived(
      connectionID: "connection-one",
      envelope: firstEnvelope,
      rawMessage: firstMessage
    )
    let secondEvent = MailEngineQualificationEvent.submissionReceived(
      connectionID: "connection-two",
      envelope: secondEnvelope,
      rawMessage: secondMessage
    )
    assertExactlyOnce(submissionEvents, events: firstEvent, secondEvent)
  }

  private func assertExactlyOnce(
    _ actualEvents: [MailEngineQualificationEvent],
    events expectedEvents: MailEngineQualificationEvent...
  ) {
    XCTAssertEqual(actualEvents.count, expectedEvents.count)
    for event in expectedEvents {
      XCTAssertEqual(actualEvents.filter { $0 == event }.count, 1)
    }
  }

  private func verifyNonIdleCancellationIsolation(
    inbox: MailEngineMailboxIdentity
  ) async throws {
    try await verifyOverlappingBodyResults(inbox: inbox)
    let first = try await connect(
      fixture: .bodyFetchUntilCancelled,
      authorization: .password(username: "first@example.com", password: "first-password"),
      connectionID: "body-fetch-one"
    ).session
    let second = try await connect(
      fixture: .bodyFetchUntilCancelled,
      authorization: .xoauth2(username: "second@example.com", accessToken: "second-token"),
      connectionID: "body-fetch-two"
    ).session
    let firstFetchTask = Task {
      try await first.fetchBodyParts(
        [MailEngineBodyPartSelector("1.TEXT")],
        for: messageIdentity("body-fetch-one", inbox, 19)
      )
    }
    let secondFetchTask = Task {
      try await second.fetchBodyParts(
        [MailEngineBodyPartSelector("2.TEXT")],
        for: messageIdentity("body-fetch-two", inbox, 29)
      )
    }
    try await factory.waitForBodyFetchStarts(2, timeout: .seconds(2))
    await assertBodyFetchRequests(inbox: inbox)
    await assertBodyFetchCancellation(
      firstFetchTask,
      failureMessage: "Cancelling the first body fetch must report cancellation."
    )
    try await assertCancelledBodyFetchPreservesSessions(first, inbox: inbox)

    await assertBodyFetchStillActive(
      secondFetchTask,
      connectionID: "body-fetch-two",
      failureMessage: "Cancelling the first body fetch must leave the second fetch active."
    )
    await assertBodyFetchCancellation(
      secondFetchTask,
      failureMessage: "Cancelling the second body fetch must report cancellation."
    )
    await assertSecondBodyFetchCancelled()
    try await assertSessionRemainsUsable(second, connectionID: "body-fetch-two")
    try await assertSMTPSessionRemainsUsable(
      second,
      connectionID: "body-fetch-two",
      preservationReason: "Body-fetch cancellation must preserve the owning SMTP transport."
    )
    try await assertFirstSessionSurvivesSecondBodyFetchCancellation(first)
  }

  private func verifyStateChangingOperationCancellationIsolation() async throws {
    try await verifyTransmittedCopyCancellation()
    try await verifyTransmittedMoveCancellation()
    try await verifyTransmittedSentAppendCancellation()
  }

  private func verifyTransmittedCopyCancellation() async throws {
    let connectionID = "cancel-in-flight-copy"
    let peerConnectionID = "cancel-in-flight-copy-peer"
    let session = try await connect(
      fixture: .stateChangingOperationUntilCancelled,
      connectionID: connectionID
    ).session
    let peer = try await connect(
      fixture: .successful,
      connectionID: peerConnectionID
    ).session
    let task = inFlightCopyTask(session, connectionID: connectionID)
    try await waitForInFlightStateChangingOperation {
      if case .copyReceived(let eventConnectionID, _, _, _, _) = $0 {
        return eventConnectionID == connectionID
      }
      return false
    }
    task.cancel()
    await assertTransmittedStateChangingOperationOutcomeUnknown(
      task,
      operation: "COPY",
      termination: "Cancelling the task"
    )
    await assertInFlightStateChangingOperationWasNotReplayed(
      connectionID: connectionID,
      expectsServiceTeardown: false
    )
    try await verifyPreservedPeerSession(session, connectionID: connectionID)
    try await verifyPreservedPeerSession(peer, connectionID: peerConnectionID)
    await session.close()
    await peer.close()
  }

  private func verifyTransmittedMoveCancellation() async throws {
    let connectionID = "cancel-in-flight-move"
    let peerConnectionID = "cancel-in-flight-move-peer"
    let session = try await connect(
      fixture: .stateChangingOperationUntilCancelled,
      connectionID: connectionID
    ).session
    let peer = try await connect(
      fixture: .successful,
      connectionID: peerConnectionID
    ).session
    let task = inFlightMoveTask(session, connectionID: connectionID)
    try await waitForInFlightStateChangingOperation {
      if case .moveReceived(let eventConnectionID, _, _, _, _) = $0 {
        return eventConnectionID == connectionID
      }
      return false
    }
    task.cancel()
    await assertTransmittedStateChangingOperationOutcomeUnknown(
      task,
      operation: "MOVE",
      termination: "Cancelling the task"
    )
    await assertInFlightStateChangingOperationWasNotReplayed(
      connectionID: connectionID,
      expectsServiceTeardown: false
    )
    try await verifyPreservedPeerSession(session, connectionID: connectionID)
    try await verifyPreservedPeerSession(peer, connectionID: peerConnectionID)
    await session.close()
    await peer.close()
  }

  private func verifyTransmittedSentAppendCancellation() async throws {
    let connectionID = "cancel-in-flight-sent-append"
    let peerConnectionID = "cancel-in-flight-sent-append-peer"
    let session = try await connect(
      fixture: .stateChangingOperationUntilCancelled,
      connectionID: connectionID
    ).session
    let peer = try await connect(
      fixture: .successful,
      connectionID: peerConnectionID
    ).session
    let task = inFlightSentAppendTask(session)
    try await waitForInFlightStateChangingOperation {
      if case .sentAppendReceived(let eventConnectionID, _, _) = $0 {
        return eventConnectionID == connectionID
      }
      return false
    }
    task.cancel()
    await assertTransmittedStateChangingOperationOutcomeUnknown(
      task,
      operation: "Sent append",
      termination: "Cancelling the task"
    )
    await assertInFlightStateChangingOperationWasNotReplayed(
      connectionID: connectionID,
      expectsServiceTeardown: false
    )
    try await verifyPreservedPeerSession(session, connectionID: connectionID)
    try await verifyPreservedPeerSession(peer, connectionID: peerConnectionID)
    await session.close()
    await peer.close()
  }

  private func assertFirstSessionSurvivesSecondBodyFetchCancellation(
    _ session: any MailEngineSession
  ) async throws {
    try await assertSessionRemainsUsable(session, connectionID: "body-fetch-one")
    try await assertSMTPSessionRemainsUsable(
      session,
      connectionID: "body-fetch-one",
      preservationReason: "Cancelling the peer body fetch must preserve this SMTP transport."
    )
  }

  private func assertCancelledBodyFetchPreservesSessions(
    _ first: any MailEngineSession,
    inbox: MailEngineMailboxIdentity
  ) async throws {
    let events = await factory.events()
    XCTAssertTrue(events.contains(.bodyFetchCancelled(connectionID: "body-fetch-one")))
    XCTAssertFalse(events.contains(.bodyFetchCancelled(connectionID: "body-fetch-two")))
    XCTAssertFalse(
      events.contains {
        if case .serviceClosed(let connectionID, service: _) = $0 {
          return connectionID == "body-fetch-one" || connectionID == "body-fetch-two"
        }
        return false
      },
      "Cancelling one body fetch must not close either account's transport."
    )
    let firstFollowUpPage = try await first.loadMetadataPage(
      mailbox: inbox,
      beforeUID: nil,
      limit: 1
    )
    XCTAssertEqual(firstFollowUpPage.messages.map(\.identity.uid), [19])
    try await assertSMTPSessionRemainsUsable(
      first,
      connectionID: "body-fetch-one",
      preservationReason: "Body-fetch cancellation must preserve the owning SMTP transport."
    )
  }

  private func assertSecondBodyFetchCancelled() async {
    let events = await factory.events()
    XCTAssertTrue(events.contains(.bodyFetchCancelled(connectionID: "body-fetch-two")))
  }

  private func verifyOverlappingBodyResults(
    inbox: MailEngineMailboxIdentity
  ) async throws {
    let first = try await connect(
      fixture: .overlappingBodyResults,
      connectionID: "body-result-one"
    ).session
    let second = try await connect(
      fixture: .overlappingBodyResults,
      connectionID: "body-result-two"
    ).session
    let firstSelector = MailEngineBodyPartSelector("1.TEXT")
    let secondSelector = MailEngineBodyPartSelector("2.TEXT")
    async let firstParts = first.fetchBodyParts(
      [firstSelector],
      for: messageIdentity("body-result-one", inbox, 19)
    )
    async let secondParts = second.fetchBodyParts(
      [secondSelector],
      for: messageIdentity("body-result-two", inbox, 29)
    )
    let (firstResult, secondResult) = try await (firstParts, secondParts)
    XCTAssertEqual(
      firstResult,
      [
        MailEngineBodyPart(
          data: Data("INBOX-44-19-1.TEXT".utf8),
          selector: firstSelector
        )
      ]
    )
    XCTAssertEqual(
      secondResult,
      [
        MailEngineBodyPart(
          data: Data("INBOX-44-29-2.TEXT".utf8),
          selector: secondSelector
        )
      ]
    )
  }

  private func assertBodyFetchRequests(inbox: MailEngineMailboxIdentity) async {
    let bodyRequests = await factory.events().filter { event in
      if case .bodyPartsRequested(let connectionID, _, _) = event {
        return connectionID == "body-fetch-one" || connectionID == "body-fetch-two"
      }
      return false
    }
    let firstRequest = MailEngineQualificationEvent.bodyPartsRequested(
      connectionID: "body-fetch-one",
      message: messageIdentity("body-fetch-one", inbox, 19),
      selectors: [MailEngineBodyPartSelector("1.TEXT")]
    )
    let secondRequest = MailEngineQualificationEvent.bodyPartsRequested(
      connectionID: "body-fetch-two",
      message: messageIdentity("body-fetch-two", inbox, 29),
      selectors: [MailEngineBodyPartSelector("2.TEXT")]
    )
    XCTAssertEqual(bodyRequests.count, 2)
    XCTAssertEqual(bodyRequests.filter { $0 == firstRequest }.count, 1)
    XCTAssertEqual(bodyRequests.filter { $0 == secondRequest }.count, 1)
  }

  private func assertBodyFetchCancellation(
    _ task: Task<[MailEngineBodyPart], Error>,
    failureMessage: String
  ) async {
    task.cancel()
    let completion = LockedBox<Result<[MailEngineBodyPart], Error>?>(nil)
    let completionObserver = Task {
      let result = await task.result
      completion.withValue { $0 = result }
    }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while completion.value == nil, clock.now < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    guard let result = completion.value else {
      completionObserver.cancel()
      XCTFail("Timed out waiting for body-fetch cancellation.")
      return
    }
    switch result {
    case .success:
      XCTFail(failureMessage)
    case .failure(let error):
      XCTAssertEqual(error as? MailEngineError, .cancelled)
    }
  }

  private func assertTaskStillPending<Success>(
    _ task: Task<Success, Error>,
    failureMessage: String
  ) async {
    let completion = LockedBox<Result<Success, Error>?>(nil)
    let completionObserver = Task {
      let result = await task.result
      completion.withValue { $0 = result }
    }
    try? await Task.sleep(for: .milliseconds(50))
    XCTAssertNil(completion.value, failureMessage)
    completionObserver.cancel()
  }

  private func assertBodyFetchStillActive<Success>(
    _ task: Task<Success, Error>,
    connectionID: String,
    failureMessage: String
  ) async {
    let completion = LockedBox<Result<Success, Error>?>(nil)
    let completionObserver = Task {
      let result = await task.result
      completion.withValue { $0 = result }
    }
    await Task.yield()
    XCTAssertNil(completion.value, failureMessage)
    let events = await factory.events()
    XCTAssertFalse(
      events.contains(.bodyFetchCancelled(connectionID: connectionID)),
      failureMessage
    )
    completionObserver.cancel()
  }

  private func assertIdleCancellation(
    _ task: Task<Void, Error>,
    failureMessage: String
  ) async {
    task.cancel()
    let completion = LockedBox<Result<Void, Error>?>(nil)
    let completionObserver = Task {
      let result = await task.result
      completion.withValue { $0 = result }
    }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while completion.value == nil, clock.now < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    guard let result = completion.value else {
      completionObserver.cancel()
      XCTFail("Timed out waiting for IDLE cancellation.")
      return
    }
    switch result {
    case .success:
      XCTFail(failureMessage)
    case .failure(let error):
      XCTAssertEqual(error as? MailEngineError, .cancelled)
    }
  }

  private func idleCancellationEvents() async -> [MailEngineQualificationEvent] {
    await factory.events().filter {
      if case .idleCancelled = $0 { return true }
      return false
    }
  }

  private func waitForIdleEvents(
    _ events: LockedBox<[MailEngineIdleEvent]>,
    count: Int,
    timeout: Duration
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while events.value.count < count {
      guard clock.now < deadline else {
        throw MailEngineQualificationHarnessError.idleEventTimedOut
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  func verifySMTPAndSentAppend() async throws {
    let (stages, expectedOutcomes) = smtpStagesAndExpectedOutcomes()
    let session = try await connect(fixture: .smtpStages(stages)).session
    let envelope = MailEngineEnvelope(
      recipients: ["first-recipient@example.com", "second-recipient@example.com"],
      sender: "sender@example.com"
    )
    let rawMessage = Data("Subject: Contract\r\n\r\nBody".utf8)
    let observed = try await submitSMTPStages(
      stages,
      session: session,
      envelope: envelope,
      rawMessage: rawMessage
    )
    XCTAssertEqual(observed, expectedOutcomes)
    try await verifySMTPCancellation()
    try await verifyPostContentSMTPCancellation()
    try await verifyPartialRecipientRejectionStopsBeforeContent()
    try await verifyInvalidSentAppendIdentities()
    try await verifyOverlappingSentAppends()
    try await verifySentAppendRecovery()

    let events = await factory.events()
    XCTAssertEqual(
      events.filter { $0 == .submitted(connectionID: "connection-a") }.count,
      stages.count + 1
    )
    XCTAssertEqual(
      events.filter {
        $0
          == .submissionReceived(
            connectionID: "connection-a",
            envelope: envelope,
            rawMessage: rawMessage
          )
      }.count,
      stages.count
    )
    XCTAssertEqual(events.filter { $0 == .sentAppend(connectionID: "connection-a") }.count, 2)
  }

  // swiftlint:disable:next function_body_length
  private func submitSMTPStages(
    _ stages: [MailEngineSMTPStage],
    session: any MailEngineSession,
    envelope: MailEngineEnvelope,
    rawMessage: Data
  ) async throws -> [MailEngineSMTPOutcome] {
    var observed: [MailEngineSMTPOutcome] = []
    var previousStage: MailEngineSMTPStage?
    for stage in stages {
      let contentBeforeSubmission = await submissionContentAcceptedMessages(
        connectionID: "connection-a"
      )
      let eventCountBeforeSubmission = await factory.events().count
      observed.append(
        try await session.submit(envelope: envelope, rawMessage: rawMessage)
      )
      let submissionEvents = Array(
        (await factory.events()).dropFirst(eventCountBeforeSubmission)
      ).filter { $0.belongs(to: "connection-a", service: .smtp) }
      if previousStage.map(smtpStageRequiresReauthentication) == true {
        XCTAssertTrue(
          submissionEvents.starts(with: [
            .tlsEstablished(
              connectionID: "connection-a",
              service: .smtp,
              version: .tls13
            ),
            .authenticationStarted(connectionID: "connection-a", service: .smtp),
            .authenticated(connectionID: "connection-a", service: .smtp),
          ]),
          "SMTP transport or authentication failure must reconnect with TLS and authentication."
        )
      }
      if smtpStageRequiresReauthentication(stage) {
        XCTAssertTrue(
          submissionEvents.contains(
            .serviceClosed(connectionID: "connection-a", service: .smtp)
          ),
          "SMTP transport or authentication failure must terminate the failed channel."
        )
      }
      if shouldWithholdMessageContent(for: stage) {
        let contentAfterSubmission = await submissionContentAcceptedMessages(
          connectionID: "connection-a"
        )
        XCTAssertEqual(
          contentAfterSubmission,
          contentBeforeSubmission,
          "A pre-DATA rejection must not transmit message content."
        )
      } else {
        let contentAfterSubmission = await submissionContentAcceptedMessages(
          connectionID: "connection-a"
        )
        XCTAssertEqual(
          contentAfterSubmission,
          contentBeforeSubmission + [rawMessage],
          "Every post-content outcome must follow transmission of the exact raw message."
        )
      }
      previousStage = stage
    }
    return observed
  }

  private func smtpStageRequiresReauthentication(_ stage: MailEngineSMTPStage) -> Bool {
    switch stage {
    case .authenticationRejectedBeforeSubmission, .transportUnavailableAfterSenderAccepted,
      .transportUnavailableBeforeSubmission, .connectionLostAfterSubmission:
      true
    case .accepted, .cancelledAfterMessageContent, .cancelledAfterSenderAccepted,
      .cancelledBeforeSubmission, .dataRejectedBeforeSubmission, .finalResponse,
      .recipientRejectedAfterAccepted, .recipientRejectedBeforeSubmission,
      .senderRejectedBeforeSubmission:
      false
    }
  }

  private func submissionContentAcceptedMessages(connectionID: String) async -> [Data] {
    await factory.events().compactMap { event in
      guard
        case .submissionContentAccepted(
          connectionID: connectionID,
          rawMessage: let rawMessage
        ) = event
      else { return nil }
      return rawMessage
    }
  }

  private func shouldWithholdMessageContent(for stage: MailEngineSMTPStage) -> Bool {
    switch stage {
    case .authenticationRejectedBeforeSubmission, .cancelledAfterSenderAccepted,
      .dataRejectedBeforeSubmission, .recipientRejectedAfterAccepted,
      .recipientRejectedBeforeSubmission, .senderRejectedBeforeSubmission,
      .transportUnavailableAfterSenderAccepted, .transportUnavailableBeforeSubmission:
      true
    case .accepted, .cancelledAfterMessageContent, .cancelledBeforeSubmission,
      .connectionLostAfterSubmission, .finalResponse:
      false
    }
  }

  private func verifyPartialRecipientRejectionStopsBeforeContent() async throws {
    for code in [451, 550] {
      let connectionID = "partial-recipient-rejection-\(code)"
      let session = try await connect(
        fixture: .smtpStages([.recipientRejectedAfterAccepted(code: code)]),
        connectionID: connectionID
      ).session
      let outcome = try await session.submit(
        envelope: MailEngineEnvelope(
          recipients: ["accepted@example.com", "rejected@example.com"],
          sender: "sender@example.com"
        ),
        rawMessage: Data("Subject: Must not be transmitted\r\n\r\nPrivate body".utf8)
      )

      XCTAssertEqual(outcome, .notSubmitted(.recipientRejected(code: code)))
      let events = await factory.events()
      XCTAssertFalse(
        events.contains {
          if case .submissionContentAccepted(connectionID: connectionID, rawMessage: _) = $0 {
            return true
          }
          return false
        },
        "DATA must not begin after any recipient is rejected."
      )
    }
  }

  private func smtpStagesAndExpectedOutcomes() -> (
    stages: [MailEngineSMTPStage],
    outcomes: [MailEngineSMTPOutcome]
  ) {
    (
      [
        .transportUnavailableBeforeSubmission,
        .authenticationRejectedBeforeSubmission,
        .senderRejectedBeforeSubmission(code: 451),
        .senderRejectedBeforeSubmission(code: 550),
        .recipientRejectedBeforeSubmission(code: 451),
        .recipientRejectedBeforeSubmission(code: 550),
        .transportUnavailableAfterSenderAccepted,
        .dataRejectedBeforeSubmission(code: 451),
        .dataRejectedBeforeSubmission(code: 550),
        .finalResponse(code: 451),
        .finalResponse(code: 499),
        .finalResponse(code: 500),
        .finalResponse(code: 550),
        .connectionLostAfterSubmission,
        .accepted(serverMessageID: "smtp-message-1"),
        .accepted(serverMessageID: nil),
      ],
      [
        .notSubmitted(.transportUnavailable),
        .notSubmitted(.authentication),
        .notSubmitted(.senderRejected(code: 451)),
        .notSubmitted(.senderRejected(code: 550)),
        .notSubmitted(.recipientRejected(code: 451)),
        .notSubmitted(.recipientRejected(code: 550)),
        .notSubmitted(.transportUnavailable),
        .notSubmitted(.dataRejected(code: 451)),
        .notSubmitted(.dataRejected(code: 550)),
        .transientlyRejected(code: 451),
        .transientlyRejected(code: 499),
        .permanentlyRejected(code: 500),
        .permanentlyRejected(code: 550),
        .ambiguous,
        .accepted(serverMessageID: "smtp-message-1"),
        .accepted(serverMessageID: nil),
      ]
    )
  }

  // swiftlint:disable:next function_body_length
  private func verifySMTPCancellation() async throws {
    let cancelledConnectionID = "pre-content-cancellation"
    let preservedConnectionID = "pre-content-cancellation-peer"
    let preservedSession = try await connect(
      fixture: .successful,
      connectionID: preservedConnectionID
    ).session
    let cancelledSession = try await connect(
      fixture: .smtpStages([.cancelledBeforeSubmission]),
      connectionID: cancelledConnectionID
    ).session
    let submissionTask = Task {
      try await cancelledSession.submit(
        envelope: MailEngineEnvelope(
          recipients: ["recipient@example.com"],
          sender: "sender@example.com"
        ),
        rawMessage: Data("Subject: Cancelled\r\n\r\nBody".utf8)
      )
    }
    try await factory.waitForSubmissionStarts(1, timeout: .seconds(2))
    submissionTask.cancel()
    await assertPreContentSMTPCancellation(submissionTask)
    try await factory.waitForSubmissionTransportTermination(
      connectionID: cancelledConnectionID,
      timeout: .seconds(2)
    )
    let contentEvents = await factory.events().filter {
      if case .submissionReceived(
        connectionID: cancelledConnectionID,
        envelope: _,
        rawMessage: _
      ) = $0 {
        return true
      }
      return false
    }
    XCTAssertEqual(contentEvents, [])
    let events = await factory.events()
    XCTAssertTrue(
      events.contains(.submissionTransportTerminated(connectionID: cancelledConnectionID)),
      "Cancellation must terminate the owning SMTP transport."
    )
    try await assertCancelledSMTPSessionRemainsUsable(
      cancelledSession,
      connectionID: cancelledConnectionID
    )
    try await assertSMTPSessionRemainsUsable(
      preservedSession,
      connectionID: preservedConnectionID
    )
    try await verifyPostEnvelopePreContentSMTPCancellation()
    try await verifySMTPCancellationTLSFloor()
  }

  private func verifySMTPCancellationTLSFloor() async throws {
    let connectionID = "smtp-reconnect-tls13-floor"
    let session = try await connect(
      fixture: .smtpCancellationReconnectMaximumTLS12,
      connectionID: connectionID,
      minimumTLSVersion: .tls13
    ).session
    let envelope = MailEngineEnvelope(
      recipients: ["recipient@example.com"],
      sender: "sender@example.com"
    )
    let rawMessage = Data("Subject: TLS floor cancellation\r\n\r\nWithheld body".utf8)
    let submission = Task {
      try await session.submit(envelope: envelope, rawMessage: rawMessage)
    }
    try await factory.waitForSubmissionEnvelopeAccepted(
      connectionID: connectionID,
      timeout: .seconds(2)
    )
    submission.cancel()
    await assertPreContentSMTPCancellation(submission)
    try await factory.waitForSubmissionTransportTermination(
      connectionID: connectionID,
      timeout: .seconds(2)
    )
    let eventCountBeforeReuse = await factory.events().count
    let reuse = Task {
      try await session.submit(envelope: envelope, rawMessage: rawMessage)
    }
    guard
      let reuseResult = await boundedResult(
        of: reuse,
        timeoutMessage: "Timed out waiting for TLS-floor SMTP reuse rejection."
      )
    else {
      return
    }
    do {
      _ = try reuseResult.get()
      XCTFail("SMTP reuse must preserve the caller's TLS 1.3 floor.")
    } catch {
      XCTAssertEqual(error as? MailEngineError, .tlsVersionUnsupported)
    }
    let reuseEvents = Array((await factory.events()).dropFirst(eventCountBeforeReuse)).filter {
      $0.belongs(to: connectionID, service: .smtp)
    }
    XCTAssertEqual(
      reuseEvents,
      [.serviceClosed(connectionID: connectionID, service: .smtp)],
      "A TLS 1.2 reconnect must be rejected before SMTP authentication."
    )
  }

  private func verifyPostEnvelopePreContentSMTPCancellation() async throws {
    let cancelledConnectionID = "post-envelope-cancellation"
    let preservedConnectionID = "post-envelope-cancellation-peer"
    let preservedSession = try await connect(
      fixture: .successful,
      connectionID: preservedConnectionID
    ).session
    let cancelledSession = try await connect(
      fixture: .smtpStages([
        .cancelledAfterSenderAccepted,
        .accepted(serverMessageID: "smtp-message-1"),
      ]),
      connectionID: cancelledConnectionID
    ).session
    let envelope = MailEngineEnvelope(
      recipients: ["recipient@example.com"],
      sender: "sender@example.com"
    )
    let rawMessage = Data("Subject: Cancel after sender\r\n\r\nWithheld body".utf8)
    let submissionTask = Task {
      try await cancelledSession.submit(envelope: envelope, rawMessage: rawMessage)
    }
    try await factory.waitForSubmissionEnvelopeAccepted(
      connectionID: cancelledConnectionID,
      timeout: .seconds(2)
    )
    submissionTask.cancel()
    await assertPreContentSMTPCancellation(submissionTask)
    try await factory.waitForSubmissionTransportTermination(
      connectionID: cancelledConnectionID,
      timeout: .seconds(2)
    )
    await assertPostEnvelopeCancellationWithheldContent(
      connectionID: cancelledConnectionID,
      envelope: envelope
    )
    try await assertCancelledSMTPSessionRemainsUsable(
      cancelledSession,
      connectionID: cancelledConnectionID
    )
    try await assertSMTPSessionRemainsUsable(
      preservedSession,
      connectionID: preservedConnectionID
    )
  }

  private func assertPostEnvelopeCancellationWithheldContent(
    connectionID: String,
    envelope: MailEngineEnvelope
  ) async {
    let events = await factory.events()
    XCTAssertEqual(
      events.filter {
        $0
          == .submissionEnvelopeAccepted(
            connectionID: connectionID,
            envelope: envelope
          )
      }.count,
      1
    )
    XCTAssertFalse(
      events.contains {
        switch $0 {
        case .submissionContentAccepted(let eventConnectionID, _),
          .submissionReceived(let eventConnectionID, _, _):
          eventConnectionID == connectionID
        default:
          false
        }
      },
      "Cancelling after sender acceptance must withhold DATA and the raw message."
    )
    XCTAssertTrue(
      events.contains(.submissionTransportTerminated(connectionID: connectionID)),
      "Post-envelope cancellation must terminate the owning SMTP transport."
    )
  }

  private func assertPreContentSMTPCancellation(
    _ submissionTask: Task<MailEngineSMTPOutcome, Error>
  ) async {
    let completion = LockedBox<Result<MailEngineSMTPOutcome, Error>?>(nil)
    let completionObserver = Task {
      let result = await submissionTask.result
      completion.withValue { $0 = result }
    }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while completion.value == nil, clock.now < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    guard let result = completion.value else {
      completionObserver.cancel()
      XCTFail("Timed out waiting for pre-content SMTP cancellation.")
      return
    }
    switch result {
    case .success:
      XCTFail("Cancellation before SMTP content should be reported.")
    case .failure(let error):
      XCTAssertEqual(error as? MailEngineError, .cancelled)
    }
  }

  private func verifyPostContentSMTPCancellation() async throws {
    let cancelledConnectionID = "post-content-cancellation"
    let preservedConnectionID = "post-content-cancellation-peer"
    let preservedSession = try await connect(
      fixture: .successful,
      connectionID: preservedConnectionID
    ).session
    let session = try await connect(
      fixture: .smtpStages([.cancelledAfterMessageContent]),
      connectionID: cancelledConnectionID
    ).session
    let envelope = MailEngineEnvelope(
      recipients: ["first-recipient@example.com", "second-recipient@example.com"],
      sender: "sender@example.com"
    )
    let rawMessage = Data("Subject: Post-content cancellation\r\n\r\nPrivate body".utf8)
    let submissionsBefore = await submissionEvents(connectionID: cancelledConnectionID)
    let contentAcceptancesBeforeSubmission = await submissionContentAcceptedMessages(
      connectionID: cancelledConnectionID
    ).count
    let submissionTask = Task {
      try await session.submit(
        envelope: envelope,
        rawMessage: rawMessage
      )
    }
    try await waitForSubmissionContent(
      after: contentAcceptancesBeforeSubmission,
      connectionID: cancelledConnectionID
    )
    submissionTask.cancel()
    await assertPostContentCancellationResult(submissionTask)
    await assertPostContentSubmission(
      envelope: envelope,
      rawMessage: rawMessage,
      previousSubmissions: submissionsBefore,
      connectionID: cancelledConnectionID
    )
    let events = await factory.events()
    XCTAssertTrue(
      events.contains(.submissionTransportTerminated(connectionID: cancelledConnectionID)),
      "Post-content cancellation must terminate the owning SMTP transport."
    )
    try await assertCancelledSMTPSessionRemainsUsable(
      session,
      connectionID: cancelledConnectionID
    )
    try await assertSMTPSessionRemainsUsable(
      preservedSession,
      connectionID: preservedConnectionID
    )
  }

  private func assertPostContentCancellationResult(
    _ submissionTask: Task<MailEngineSMTPOutcome, Error>,
    timeoutMessage: String = "Timed out waiting for post-content SMTP cancellation."
  ) async {
    let completion = LockedBox<Result<MailEngineSMTPOutcome, Error>?>(nil)
    let completionObserver = Task {
      let result = await submissionTask.result
      completion.withValue { $0 = result }
    }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while completion.value == nil, clock.now < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    guard let result = completion.value else {
      completionObserver.cancel()
      XCTFail(timeoutMessage)
      return
    }
    switch result {
    case .success(let outcome):
      XCTAssertEqual(outcome, .ambiguous)
    case .failure(let error):
      XCTFail("Post-content cancellation must be ambiguous, not \(error).")
    }
  }

  private func assertPostContentSubmission(
    envelope: MailEngineEnvelope,
    rawMessage: Data,
    previousSubmissions: [MailEngineQualificationEvent],
    connectionID: String
  ) async {
    let submissionsAfter = await submissionEvents(connectionID: connectionID)
    XCTAssertEqual(
      submissionsAfter,
      previousSubmissions + [
        .submissionReceived(
          connectionID: connectionID,
          envelope: envelope,
          rawMessage: rawMessage
        )
      ],
      "Post-content cancellation must preserve the exact accepted envelope and message."
    )
  }

  private func waitForSubmissionContent(after count: Int, connectionID: String) async throws {
    try await factory.waitForSubmissionContentStarts(
      count + 1,
      connectionID: connectionID,
      timeout: .seconds(2)
    )
  }

  private func submissionEvents(connectionID: String) async -> [MailEngineQualificationEvent] {
    await factory.events().filter {
      if case .submissionReceived(let eventConnectionID, _, _) = $0 {
        return eventConnectionID == connectionID
      }
      return false
    }
  }

  private func assertSMTPSessionRemainsUsable(
    _ session: any MailEngineSession,
    connectionID: String,
    preservationReason: String = "Cancelling an SMTP submission must preserve connected sessions.",
    allowPriorIMAPClose: Bool = false,
    expectedServerMessageID: String = "smtp-message-1"
  ) async throws {
    if allowPriorIMAPClose {
      await assertNoSMTPServiceClose(
        connectionID: connectionID,
        failureMessage: preservationReason
      )
    } else {
      await assertNoServiceClose(
        connectionID: connectionID,
        failureMessage: preservationReason
      )
    }
    let envelope = MailEngineEnvelope(
      recipients: ["peer-recipient@example.com"],
      sender: "peer-sender@example.com"
    )
    let rawMessage = Data("Subject: Peer remains active\r\n\r\nBody".utf8)
    let submissionsBefore = await submissionEvents(connectionID: connectionID)
    let submission = Task {
      try await session.submit(
        envelope: envelope,
        rawMessage: rawMessage
      )
    }
    guard
      let submissionResult = await boundedResult(
        of: submission,
        timeoutMessage: "Timed out waiting for follow-up SMTP submission."
      )
    else {
      return
    }
    let outcome = try submissionResult.get()
    XCTAssertEqual(outcome, .accepted(serverMessageID: expectedServerMessageID))
    let submissionsAfter = await submissionEvents(connectionID: connectionID)
    XCTAssertEqual(
      submissionsAfter,
      submissionsBefore + [
        .submissionReceived(
          connectionID: connectionID,
          envelope: envelope,
          rawMessage: rawMessage
        )
      ],
      "The follow-up submission must use the same account's SMTP transport."
    )
  }

  private func assertCancelledSMTPSessionRemainsUsable(
    _ session: any MailEngineSession,
    connectionID: String
  ) async throws {
    try await assertSessionRemainsUsable(session, connectionID: connectionID)
    let eventCountBeforeSubmission = await factory.events().count
    try await assertSMTPSessionRemainsUsable(session, connectionID: connectionID)
    let smtpEvents = Array((await factory.events()).dropFirst(eventCountBeforeSubmission)).filter {
      $0.belongs(to: connectionID, service: .smtp)
    }
    guard
      case .tlsEstablished(
        connectionID: connectionID,
        service: .smtp,
        version: let negotiatedVersion
      ) = smtpEvents.first
    else {
      XCTFail("SMTP reuse after cancellation must establish a fresh secure transport.")
      return
    }
    XCTAssertGreaterThanOrEqual(negotiatedVersion, .tls12)
    XCTAssertEqual(
      Array(smtpEvents.dropFirst()),
      [
        .authenticationStarted(connectionID: connectionID, service: .smtp),
        .authenticated(connectionID: connectionID, service: .smtp),
      ],
      "SMTP reuse after cancellation must authenticate before the next submission."
    )
  }

  private func verifySentAppendRecovery() async throws {
    let connection = try await connect(fixture: .sentAppendFailsOnce)
    let sentRecoverySession = connection.session
    let sentMailbox = try XCTUnwrap(
      connection.snapshot.mailboxes.first { $0.specialUses.contains(.sent) }?.identity
    )
    let rawMessage = Data("Subject: Sent recovery\r\n\r\nBody".utf8)
    let accepted = try await sentRecoverySession.submit(
      envelope: MailEngineEnvelope(
        recipients: ["recipient@example.com"],
        sender: "sender@example.com"
      ),
      rawMessage: rawMessage
    )
    XCTAssertEqual(accepted, .accepted(serverMessageID: "smtp-message-1"))
    do {
      _ = try await sentRecoverySession.appendToSent(
        rawMessage,
        mailbox: sentMailbox
      )
      XCTFail("The first Sent append should fail.")
    } catch {
      XCTAssertEqual(
        error as? MailEngineError,
        .protocolRejected(code: "TRYAGAIN", retryable: true)
      )
    }
    let appended = try await sentRecoverySession.appendToSent(
      rawMessage,
      mailbox: sentMailbox
    )
    XCTAssertEqual(
      appended,
      messageIdentity("connection-a", sentMailbox, 11, 45)
    )
    await assertSentRecoveryEvents(rawMessage: rawMessage, sentMailbox: sentMailbox)
  }

  private func verifyInvalidSentAppendIdentities() async throws {
    let sentMailbox = MailEngineMailboxIdentity("Transmitted Items")
    let fixtures: [(fixture: MailEngineQualificationFixture, expected: MailEngineUIDMappingError)] =
      [
        (.missingSentAppendIdentity, .invalidUID),
        (.invalidSentAppendIdentity(uid: -1, uidValidity: 45), .invalidUID),
        (.invalidSentAppendIdentity(uid: 0, uidValidity: 45), .invalidUID),
        (.invalidSentAppendIdentity(uid: 4_294_967_296, uidValidity: 45), .invalidUID),
        (.invalidSentAppendIdentity(uid: 11, uidValidity: -1), .invalidSourceUIDValidity),
        (.invalidSentAppendIdentity(uid: 11, uidValidity: 0), .invalidSourceUIDValidity),
        (
          .invalidSentAppendIdentity(uid: 11, uidValidity: 4_294_967_296),
          .invalidSourceUIDValidity
        ),
      ]
    for (index, testCase) in fixtures.enumerated() {
      let connectionID = "invalid-sent-append-\(index)"
      let rawMessage = Data("invalid identity".utf8)
      let session = try await connect(
        fixture: testCase.fixture,
        connectionID: connectionID
      ).session
      do {
        _ = try await session.appendToSent(rawMessage, mailbox: sentMailbox)
        XCTFail("Malformed APPENDUID identities must be rejected.")
      } catch {
        XCTAssertEqual(error as? MailEngineUIDMappingError, testCase.expected)
      }
      let attempts = await factory.events().filter {
        $0
          == .sentAppendReceived(
            connectionID: connectionID,
            mailbox: sentMailbox,
            rawMessage: rawMessage
          )
      }
      XCTAssertEqual(
        attempts.count,
        1,
        "A malformed APPENDUID identity must not cause a duplicate Sent append."
      )
    }
  }

  private func verifyOverlappingSentAppends() async throws {
    let firstMailbox = MailEngineMailboxIdentity("First Sent")
    let secondMailbox = MailEngineMailboxIdentity("Second Sent")
    let firstMessage = Data("Subject: First append\r\n\r\nFirst body".utf8)
    let secondMessage = Data("Subject: Second append\r\n\r\nSecond body".utf8)
    let firstSession = try await connect(
      fixture: .overlappingSentAppend(uid: 101, uidValidity: 45),
      connectionID: "sent-append-one"
    ).session
    let secondSession = try await connect(
      fixture: .overlappingSentAppend(uid: 202, uidValidity: 73),
      connectionID: "sent-append-two"
    ).session
    async let firstIdentity = firstSession.appendToSent(firstMessage, mailbox: firstMailbox)
    async let secondIdentity = secondSession.appendToSent(secondMessage, mailbox: secondMailbox)
    let identities = try await (firstIdentity, secondIdentity)
    XCTAssertEqual(
      identities.0,
      messageIdentity("sent-append-one", firstMailbox, 101, 45)
    )
    XCTAssertEqual(
      identities.1,
      messageIdentity("sent-append-two", secondMailbox, 202, 73)
    )
    let events = await factory.events().filter {
      if case .sentAppendReceived(let connectionID, _, _) = $0 {
        return connectionID == "sent-append-one" || connectionID == "sent-append-two"
      }
      return false
    }
    assertExactlyOnce(
      events,
      events:
        .sentAppendReceived(
          connectionID: "sent-append-one",
          mailbox: firstMailbox,
          rawMessage: firstMessage
        ),
      .sentAppendReceived(
        connectionID: "sent-append-two",
        mailbox: secondMailbox,
        rawMessage: secondMessage
      )
    )
  }

  private func assertSentRecoveryEvents(
    rawMessage: Data,
    sentMailbox: MailEngineMailboxIdentity
  ) async {
    let events = await factory.events()
    XCTAssertEqual(
      events.filter {
        $0
          == .sentAppendReceived(
            connectionID: "connection-a",
            mailbox: sentMailbox,
            rawMessage: rawMessage
          )
      }.count,
      2
    )
    XCTAssertEqual(
      events.filter {
        $0
          == .submissionReceived(
            connectionID: "connection-a",
            envelope: MailEngineEnvelope(
              recipients: ["recipient@example.com"],
              sender: "sender@example.com"
            ),
            rawMessage: rawMessage
          )
      }.count,
      1,
      "Sent append recovery must not submit an already accepted message again."
    )
  }

  func verifyProtocolTracePrivacy() async throws {
    let sink = RecordingMailEngineProductionLogSink()
    let logger = PrivacyPreservingMailEngineLogger(sink: sink)
    try await exercisePrivateAuthenticationPaths(logger: logger)
    let (oauthSession, passwordSession) = try await connectPrivacySessions(logger: logger)
    try await exercisePrivateOperations(
      oauthSession: oauthSession,
      passwordSession: passwordSession
    )
    await oauthSession.close()
    await passwordSession.close()

    await assertCandidateOutputContainsNoQualificationSecrets()
  }

  private func exercisePrivateAuthenticationPaths(
    logger: any MailEngineLogging
  ) async throws {
    for service in [MailEngineService.imap, .smtp] {
      let fixture = MailEngineQualificationFixture.xoauth2Challenge(service: service)
      let session = try await factory.makeEngine(fixture: fixture).connect(
        configuration: configuration(
          fixture: fixture,
          authorization: .xoauth2(
            username: "private-challenge@example.com",
            accessToken: "private-challenge-token"
          ),
          connectionID: "privacy-challenge-\(service)"
        ),
        logger: logger
      ).session
      await session.close()
    }

    let rejectedAuthorizations = [
      MailEngineAuthorization.password(
        username: "private-rejected-password@example.com",
        password: "private-rejected-password"
      ),
      .xoauth2(
        username: "private-rejected-oauth@example.com",
        accessToken: "private-rejected-token"
      ),
    ]
    for service in [MailEngineService.imap, .smtp] {
      for (index, authorization) in rejectedAuthorizations.enumerated() {
        let fixture = MailEngineQualificationFixture.connectionFailure(
          service: service,
          error: .authenticationRejected
        )
        do {
          let session = try await factory.makeEngine(fixture: fixture).connect(
            configuration: configuration(
              fixture: fixture,
              authorization: authorization,
              connectionID: "privacy-rejection-\(service)-\(index)"
            ),
            logger: logger
          ).session
          await session.close()
          XCTFail("The private authentication-rejection fixture must reject the connection.")
        } catch {
          XCTAssertEqual(error as? MailEngineError, .authenticationRejected)
        }
      }
    }
  }

  private func connectPrivacySessions(
    logger: any MailEngineLogging
  ) async throws -> (oauth: any MailEngineSession, password: any MailEngineSession) {
    let oauthSession = try await factory.makeEngine(fixture: .successful).connect(
      configuration: configuration(
        fixture: .successful,
        authorization: .xoauth2(
          username: "private-mailbox@example.com",
          accessToken: "private-bearer-token"
        ),
        connectionID: "privacy-oauth"
      ),
      logger: logger
    ).session
    let passwordSession = try await factory.makeEngine(fixture: .successful).connect(
      configuration: configuration(
        fixture: .successful,
        authorization: .password(
          username: "private-password-mailbox@example.com",
          password: "private-password"
        ),
        connectionID: "privacy-password"
      ),
      logger: logger
    ).session
    return (oauthSession, passwordSession)
  }

  private func exercisePrivateOperations(
    oauthSession: any MailEngineSession,
    passwordSession: any MailEngineSession
  ) async throws {
    let privateMailbox = MailEngineMailboxIdentity("private-mailbox")
    _ = try await oauthSession.fetchBodyParts(
      [MailEngineBodyPartSelector("private-body.TEXT")],
      for: messageIdentity("privacy-oauth", privateMailbox, 19)
    )
    _ = try await passwordSession.submit(
      envelope: MailEngineEnvelope(
        recipients: ["private-recipient@example.com"],
        sender: "private-sender@example.com"
      ),
      rawMessage: Data("Subject: private SMTP message\r\n\r\nprivate SMTP body".utf8)
    )
    let appendMessage = Data("Subject: private append message\r\n\r\nprivate append body".utf8)
    let sentMailbox = MailEngineMailboxIdentity("private-sent-mailbox")
    let appendIdentity = try await oauthSession.appendToSent(
      appendMessage,
      mailbox: sentMailbox
    )
    XCTAssertEqual(
      appendIdentity,
      messageIdentity("privacy-oauth", sentMailbox, 11, 45)
    )
    let privacyAppendEvents = await factory.events().filter {
      if case .sentAppendReceived(let connectionID, _, _) = $0 {
        return connectionID == "privacy-oauth" || connectionID == "privacy-password"
      }
      return false
    }
    XCTAssertEqual(
      privacyAppendEvents,
      [
        .sentAppendReceived(
          connectionID: "privacy-oauth",
          mailbox: sentMailbox,
          rawMessage: appendMessage
        )
      ],
      "The private Sent append must use only the OAuth account's IMAP transport."
    )
  }

  private func assertCandidateOutputContainsNoQualificationSecrets() async {
    assertUnpaddedBase64RecordsAreDecoded()
    let candidateOutput = await factory.capturedCandidateLogOutput()
    let secrets = [
      "private-mailbox@example.com",
      "private-bearer-token",
      "private-password-mailbox@example.com",
      "private-password",
      "private-challenge@example.com",
      "private-challenge-token",
      "private-rejected-password@example.com",
      "private-rejected-password",
      "private-rejected-oauth@example.com",
      "private-rejected-token",
      "private-mailbox",
      "private message",
      "private-body.TEXT",
      "private-recipient@example.com",
      "private-sender@example.com",
      "private SMTP message",
      "private SMTP body",
      "private-sent-mailbox",
      "private append message",
      "private append body",
    ]
    let authenticationExchanges = [
      Data(
        "user=private-mailbox@example.com\u{1}auth=Bearer private-bearer-token\u{1}\u{1}".utf8
      ),
      Data("\0private-password-mailbox@example.com\0private-password".utf8),
      Data("private-password-mailbox@example.com".utf8),
      Data("private-password".utf8),
    ]
    let messagePayloads = [
      Data("private-mailbox-44-19-private-body.TEXT".utf8),
      Data("Subject: private SMTP message\r\n\r\nprivate SMTP body".utf8),
      Data("Subject: private append message\r\n\r\nprivate append body".utf8),
    ]
    var inspectedOutput = candidateOutput
    inspectedOutput.append(recursivelyDecodedBase64Records(in: candidateOutput))
    for secret in secrets.map({ Data($0.utf8) }) + authenticationExchanges + messagePayloads {
      XCTAssertFalse(
        inspectedOutput.range(of: secret) != nil,
        "Candidate-owned logging leaked a qualification secret."
      )
    }
  }

  private func assertUnpaddedBase64RecordsAreDecoded() {
    let password = Data("private-password".utf8)
    var unpaddedPassword = password.base64EncodedData()
    while unpaddedPassword.last == UInt8(ascii: "=") {
      unpaddedPassword.removeLast()
    }
    XCTAssertNotNil(decodedBase64Records(in: unpaddedPassword).range(of: password))
    var fieldPrefixedPassword = Data("payload=".utf8)
    fieldPrefixedPassword.append(password.base64EncodedData())
    XCTAssertNotNil(decodedBase64Records(in: fieldPrefixedPassword).range(of: password))
    let nestedPassword = password.base64EncodedData().base64EncodedData()
    XCTAssertNotNil(recursivelyDecodedBase64Records(in: nestedPassword).range(of: password))
    let encodedPassword = password.base64EncodedString()
    let splitIndex = encodedPassword.index(encodedPassword.startIndex, offsetBy: 5)
    let wrappedPassword = Data(
      (String(encodedPassword[..<splitIndex])
        + "\r\n"
        + String(encodedPassword[splitIndex...])).utf8
    )
    XCTAssertNotNil(decodedBase64Records(in: wrappedPassword).range(of: password))
  }

  private func recursivelyDecodedBase64Records(in output: Data) -> Data {
    var decodedLayers = Data()
    var currentLayer = output
    for _ in 0..<8 {
      let decodedLayer = decodedBase64Records(in: currentLayer)
      guard !decodedLayer.isEmpty else { break }
      decodedLayers.append(decodedLayer)
      currentLayer = decodedLayer
    }
    return decodedLayers
  }

  // swiftlint:disable:next function_body_length
  private func decodedBase64Records(in output: Data) -> Data {
    let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=".utf8)
    var decodedRecords = Data()
    var records = [[Data]]()
    var currentRecord = [Data]()
    var currentToken = Data()

    func decode(_ token: Data) -> Data? {
      let assignmentIndex = token.indices.last { index in
        guard token[index] == UInt8(ascii: "=") else { return false }
        let valueStart = token.index(after: index)
        return valueStart < token.endIndex
          && token[valueStart...].contains { $0 != UInt8(ascii: "=") }
      }
      var encodedToken =
        assignmentIndex.map { Data(token[token.index(after: $0)...]) } ?? token
      guard encodedToken.count >= 4 else {
        return nil
      }
      let remainder = encodedToken.count % 4
      guard remainder != 1 else {
        return nil
      }
      if remainder > 0 {
        encodedToken.append(
          contentsOf: repeatElement(UInt8(ascii: "="), count: 4 - remainder)
        )
      }
      return Data(base64Encoded: encodedToken)
    }

    func finishToken() {
      guard !currentToken.isEmpty else { return }
      currentRecord.append(currentToken)
      currentToken.removeAll(keepingCapacity: true)
    }

    func finishRecord() {
      finishToken()
      guard !currentRecord.isEmpty else { return }
      records.append(currentRecord)
      currentRecord.removeAll(keepingCapacity: true)
    }

    for byte in output {
      if alphabet.contains(byte) {
        currentToken.append(byte)
      } else if byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x20 {
        finishToken()
      } else {
        finishRecord()
      }
    }
    finishRecord()
    for record in records {
      for token in record {
        if let decoded = decode(token) {
          decodedRecords.append(decoded)
          decodedRecords.append(0)
        }
      }
      if record.count > 1,
        let decoded = decode(record.reduce(into: Data(), { $0.append($1) }))
      {
        decodedRecords.append(decoded)
        decodedRecords.append(0)
      }
    }
    return decodedRecords
  }

  func verifyConnectionLifecycle() async throws {
    try await verifyCloseAfterSMTPContentIsAmbiguous()
    try await verifyInFlightConnectionClose()
  }

  private func verifyInFlightConnectionClose() async throws {
    try await verifyInFlightIdleClose()
    try await verifyInFlightBodyFetchAndSubmissionClose()
    try await verifyInFlightStateChangingOperationClose()
  }

  private func verifyInFlightIdleClose() async throws {
    let connectionID = "close-in-flight-idle"
    let peerConnectionID = "close-in-flight-idle-peer"
    let session = try await connect(
      fixture: .inFlightOperationsUntilClosed,
      connectionID: connectionID
    ).session
    let peer = try await connect(
      fixture: .successful,
      connectionID: peerConnectionID
    ).session
    let callbacks = LockedBox<[MailEngineIdleEvent]>([])
    let idleTask = inFlightIdleTask(session, callbacks: callbacks)
    try await factory.waitForIdleStarts(1, timeout: .seconds(2))
    try await waitForIdleEvents(callbacks, count: 1, timeout: .seconds(2))
    let callbacksBeforeClose = callbacks.value
    guard await assertCloseCompletes(session, connectionID: connectionID) else {
      _ = await assertCloseCompletes(peer, connectionID: peerConnectionID)
      return
    }
    await assertInFlightOperationClosed(idleTask)
    assertNoIdleCallbacks(callbacks, after: callbacksBeforeClose)
    try await verifyPreservedPeerSession(peer, connectionID: peerConnectionID)
    let eventsBeforeClosedOperations = await factory.events()
    let contentAfterClose = await submissionContentAcceptedMessages(connectionID: connectionID)
    await assertClosedOperations(session, connectionID: connectionID)
    try await factory.waitForClosedSessionQuiescence(
      connectionID: connectionID,
      timeout: .seconds(2)
    )
    let events = await factory.events()
    await assertClosedSessionRemainedQuiescent(
      events,
      baselineEvents: eventsBeforeClosedOperations,
      baselineContent: contentAfterClose,
      connectionID: connectionID
    )
    assertNoIdleCallbacks(callbacks, after: callbacksBeforeClose)
    XCTAssertTrue(events.contains(.closed(connectionID: connectionID)))
    assertServiceTeardownEvents(events, connectionID: connectionID)
    _ = await assertCloseCompletes(peer, connectionID: peerConnectionID)
  }

  private func verifyInFlightBodyFetchAndSubmissionClose() async throws {
    let connectionID = "close-in-flight-body-fetch"
    let peerConnectionID = "close-in-flight-body-fetch-peer"
    let session = try await connect(
      fixture: .inFlightOperationsUntilClosed,
      connectionID: connectionID
    ).session
    let peer = try await connect(
      fixture: .successful,
      connectionID: peerConnectionID
    ).session
    let bodyFetchTask = inFlightBodyFetchTask(session, connectionID: connectionID)
    let submissionTask = inFlightSubmissionTask(session)
    try await factory.waitForBodyFetchStarts(1, timeout: .seconds(2))
    try await factory.waitForSubmissionStarts(1, timeout: .seconds(2))
    let contentBeforeClose = await submissionContentAcceptedMessages(
      connectionID: connectionID
    )
    guard await assertCloseCompletes(session, connectionID: connectionID) else {
      _ = await assertCloseCompletes(peer, connectionID: peerConnectionID)
      return
    }
    await assertInFlightOperationClosed(bodyFetchTask)
    await assertInFlightOperationClosed(submissionTask)
    await assertNoSubmissionContentAccepted(connectionID: connectionID)
    try await verifyPreservedPeerSession(peer, connectionID: peerConnectionID)
    let eventsBeforeClosedOperations = await factory.events()
    await assertClosedOperations(session, connectionID: connectionID)
    try await factory.waitForClosedSessionQuiescence(
      connectionID: connectionID,
      timeout: .seconds(2)
    )
    let events = await factory.events()
    await assertClosedSessionRemainedQuiescent(
      events,
      baselineEvents: eventsBeforeClosedOperations,
      baselineContent: contentBeforeClose,
      connectionID: connectionID
    )
    XCTAssertTrue(events.contains(.closed(connectionID: connectionID)))
    assertServiceTeardownEvents(events, connectionID: connectionID)
    _ = await assertCloseCompletes(peer, connectionID: peerConnectionID)
  }

  private func verifyCloseAfterSMTPContentIsAmbiguous() async throws {
    let connectionID = "close-after-smtp-content"
    let peerConnectionID = "close-after-smtp-content-peer"
    let preservedSession = try await connect(
      fixture: .successful,
      connectionID: peerConnectionID
    ).session
    let session = try await connect(
      fixture: .smtpStages([.cancelledAfterMessageContent]),
      connectionID: connectionID
    ).session
    let envelope = MailEngineEnvelope(
      recipients: ["recipient@example.com"],
      sender: "sender@example.com"
    )
    let rawMessage = Data("Subject: Close after DATA\r\n\r\nPrivate body".utf8)
    let submissionsBefore = await submissionEvents(connectionID: connectionID)
    let contentBefore = await submissionContentAcceptedMessages(connectionID: connectionID).count
    let task = Task {
      try await session.submit(
        envelope: envelope,
        rawMessage: rawMessage
      )
    }
    try await waitForSubmissionContent(after: contentBefore, connectionID: connectionID)
    guard await assertCloseCompletes(session, connectionID: connectionID) else {
      _ = await assertCloseCompletes(preservedSession, connectionID: peerConnectionID)
      return
    }
    await assertCloseAfterSMTPContent(
      task,
      connectionID: connectionID,
      envelope: envelope,
      rawMessage: rawMessage,
      submissionsBefore: submissionsBefore
    )
    try await verifyClosedSMTPContentSession(session, connectionID: connectionID)
    try await verifyPreservedPeerSession(
      preservedSession,
      connectionID: peerConnectionID
    )
    _ = await assertCloseCompletes(preservedSession, connectionID: peerConnectionID)
  }

  private func assertCloseAfterSMTPContent(
    _ task: Task<MailEngineSMTPOutcome, Error>,
    connectionID: String,
    envelope: MailEngineEnvelope,
    rawMessage: Data,
    submissionsBefore: [MailEngineQualificationEvent]
  ) async {
    await assertPostContentCancellationResult(
      task,
      timeoutMessage: "Timed out waiting for SMTP completion after close."
    )
    let events = await factory.events()
    let submissionsAfterClose = await submissionEvents(connectionID: connectionID)
    XCTAssertEqual(
      submissionsAfterClose,
      submissionsBefore + [
        .submissionReceived(
          connectionID: connectionID,
          envelope: envelope,
          rawMessage: rawMessage
        )
      ],
      "Closing after SMTP content must not replay the accepted submission."
    )
    XCTAssertTrue(events.contains(.closed(connectionID: connectionID)))
    XCTAssertTrue(
      events.contains(.serviceClosed(connectionID: connectionID, service: .smtp)),
      "Closing after SMTP content must terminate the owning SMTP transport."
    )
    XCTAssertTrue(
      events.contains(.serviceClosed(connectionID: connectionID, service: .imap)),
      "Closing after SMTP content must terminate the owning IMAP transport."
    )
  }

  private func verifyClosedSMTPContentSession(
    _ session: any MailEngineSession,
    connectionID: String
  ) async throws {
    let eventsBeforeClosedOperations = await factory.events()
    let contentAfterClose = await submissionContentAcceptedMessages(connectionID: connectionID)
    await assertClosedOperations(session, connectionID: connectionID)
    try await factory.waitForClosedSessionQuiescence(
      connectionID: connectionID,
      timeout: .seconds(2)
    )
    await assertClosedSessionRemainedQuiescent(
      await factory.events(),
      baselineEvents: eventsBeforeClosedOperations,
      baselineContent: contentAfterClose,
      connectionID: connectionID
    )
  }

  private func assertClosedSessionRemainedQuiescent(
    _ events: [MailEngineQualificationEvent],
    baselineEvents: [MailEngineQualificationEvent],
    baselineContent: [Data],
    connectionID: String = "connection-a"
  ) async {
    let content = await submissionContentAcceptedMessages(connectionID: connectionID)
    XCTAssertEqual(
      events,
      baselineEvents,
      "Closed-session operations must not reach the server fixture."
    )
    XCTAssertEqual(
      content,
      baselineContent,
      "Closing a session must prevent detached SMTP work from accepting content later."
    )
  }

  private func verifyPreservedPeerSession(
    _ session: any MailEngineSession,
    connectionID: String = "connection-b"
  ) async throws {
    try await assertSessionRemainsUsable(session, connectionID: connectionID)
    try await assertSMTPSessionRemainsUsable(
      session,
      connectionID: connectionID,
      preservationReason: "Closing one session must preserve the peer SMTP transport."
    )
  }

  private func assertNoIdleCallbacks(
    _ callbacks: LockedBox<[MailEngineIdleEvent]>,
    after expected: [MailEngineIdleEvent]
  ) {
    XCTAssertEqual(
      callbacks.value,
      expected,
      "No callback may be delivered after session close begins."
    )
  }

  private func inFlightSubmissionTask(
    _ session: any MailEngineSession
  ) -> Task<Void, Error> {
    Task {
      _ = try await session.submit(
        envelope: MailEngineEnvelope(
          recipients: ["recipient@example.com"],
          sender: "sender@example.com"
        ),
        rawMessage: Data("Subject: Close before DATA\r\n\r\nPrivate body".utf8)
      )
    }
  }

  private func inFlightIdleTask(
    _ session: any MailEngineSession,
    callbacks: LockedBox<[MailEngineIdleEvent]>
  ) -> Task<Void, Error> {
    Task {
      try await session.idle(mailbox: MailEngineMailboxIdentity("INBOX")) { event in
        callbacks.withValue { $0.append(event) }
      }
    }
  }

  private func inFlightBodyFetchTask(
    _ session: any MailEngineSession,
    connectionID: String
  ) -> Task<Void, Error> {
    Task {
      _ = try await session.fetchBodyParts(
        [MailEngineBodyPartSelector("1.TEXT")],
        for: MailEngineMessageIdentity(
          connectionID: connectionID,
          mailbox: MailEngineMailboxIdentity("INBOX"),
          uid: 9,
          uidValidity: 44
        )
      )
    }
  }

  private func inFlightCopyTask(
    _ session: any MailEngineSession,
    connectionID: String
  ) -> Task<MailEngineUIDMapping, Error> {
    Task {
      try await session.copy(
        messages: messageIdentities(
          connectionID: connectionID,
          mailbox: MailEngineMailboxIdentity("INBOX"),
          uidValidity: 44,
          uids: [9]
        ),
        to: MailEngineMailboxIdentity("Archive")
      )
    }
  }

  private func inFlightMoveTask(
    _ session: any MailEngineSession,
    connectionID: String
  ) -> Task<MailEngineUIDMapping, Error> {
    Task {
      try await session.move(
        messages: messageIdentities(
          connectionID: connectionID,
          mailbox: MailEngineMailboxIdentity("INBOX"),
          uidValidity: 44,
          uids: [10]
        ),
        to: MailEngineMailboxIdentity("Archive")
      )
    }
  }

  private func inFlightSentAppendTask(
    _ session: any MailEngineSession
  ) -> Task<MailEngineMessageIdentity, Error> {
    Task {
      try await session.appendToSent(
        Data("Subject: In-flight Sent append\r\n\r\nPrivate body".utf8),
        mailbox: MailEngineMailboxIdentity("Transmitted Items")
      )
    }
  }

  private func verifyInFlightStateChangingOperationClose() async throws {
    try await verifyInFlightCopyClose()
    try await verifyInFlightMoveClose()
    try await verifyInFlightSentAppendClose()
  }

  private func verifyInFlightCopyClose() async throws {
    let connectionID = "close-in-flight-copy"
    let peerConnectionID = "close-in-flight-copy-peer"
    let session = try await connect(
      fixture: .inFlightOperationsUntilClosed,
      connectionID: connectionID
    ).session
    let peer = try await connect(
      fixture: .successful,
      connectionID: peerConnectionID
    ).session
    let task = inFlightCopyTask(session, connectionID: connectionID)
    try await waitForInFlightStateChangingOperation {
      if case .copyReceived(let eventConnectionID, _, _, _, _) = $0 {
        return eventConnectionID == connectionID
      }
      return false
    }
    guard await assertCloseCompletes(session, connectionID: connectionID) else {
      _ = await assertCloseCompletes(peer, connectionID: peerConnectionID)
      return
    }
    await assertTransmittedStateChangingOperationOutcomeUnknown(
      task,
      operation: "COPY",
      termination: "Closing the session"
    )
    await assertInFlightStateChangingOperationWasNotReplayed(
      connectionID: connectionID
    )
    try await assertClosedStateChangingOperationSession(session, connectionID: connectionID)
    try await verifyPreservedPeerSession(peer, connectionID: peerConnectionID)
    _ = await assertCloseCompletes(peer, connectionID: peerConnectionID)
  }

  private func verifyInFlightMoveClose() async throws {
    let connectionID = "close-in-flight-move"
    let peerConnectionID = "close-in-flight-move-peer"
    let session = try await connect(
      fixture: .inFlightOperationsUntilClosed,
      connectionID: connectionID
    ).session
    let peer = try await connect(
      fixture: .successful,
      connectionID: peerConnectionID
    ).session
    let task = inFlightMoveTask(session, connectionID: connectionID)
    try await waitForInFlightStateChangingOperation {
      if case .moveReceived(let eventConnectionID, _, _, _, _) = $0 {
        return eventConnectionID == connectionID
      }
      return false
    }
    guard await assertCloseCompletes(session, connectionID: connectionID) else {
      _ = await assertCloseCompletes(peer, connectionID: peerConnectionID)
      return
    }
    await assertTransmittedStateChangingOperationOutcomeUnknown(
      task,
      operation: "MOVE",
      termination: "Closing the session"
    )
    await assertInFlightStateChangingOperationWasNotReplayed(
      connectionID: connectionID
    )
    try await assertClosedStateChangingOperationSession(session, connectionID: connectionID)
    try await verifyPreservedPeerSession(peer, connectionID: peerConnectionID)
    _ = await assertCloseCompletes(peer, connectionID: peerConnectionID)
  }

  private func verifyInFlightSentAppendClose() async throws {
    let connectionID = "close-in-flight-sent-append"
    let peerConnectionID = "close-in-flight-sent-append-peer"
    let session = try await connect(
      fixture: .inFlightOperationsUntilClosed,
      connectionID: connectionID
    ).session
    let peer = try await connect(
      fixture: .successful,
      connectionID: peerConnectionID
    ).session
    let task = inFlightSentAppendTask(session)
    try await waitForInFlightStateChangingOperation {
      if case .sentAppendReceived(let eventConnectionID, _, _) = $0 {
        return eventConnectionID == connectionID
      }
      return false
    }
    guard await assertCloseCompletes(session, connectionID: connectionID) else {
      _ = await assertCloseCompletes(peer, connectionID: peerConnectionID)
      return
    }
    await assertTransmittedStateChangingOperationOutcomeUnknown(
      task,
      operation: "Sent append",
      termination: "Closing the session"
    )
    await assertInFlightStateChangingOperationWasNotReplayed(
      connectionID: connectionID
    )
    try await assertClosedStateChangingOperationSession(session, connectionID: connectionID)
    try await verifyPreservedPeerSession(peer, connectionID: peerConnectionID)
    _ = await assertCloseCompletes(peer, connectionID: peerConnectionID)
  }

  private func assertClosedStateChangingOperationSession(
    _ session: any MailEngineSession,
    connectionID: String
  ) async throws {
    let eventsBeforeClosedOperations = await factory.events()
    let contentAfterClose = await submissionContentAcceptedMessages(connectionID: connectionID)
    await assertClosedOperations(session, connectionID: connectionID)
    try await factory.waitForClosedSessionQuiescence(
      connectionID: connectionID,
      timeout: .seconds(2)
    )
    await assertClosedSessionRemainedQuiescent(
      await factory.events(),
      baselineEvents: eventsBeforeClosedOperations,
      baselineContent: contentAfterClose,
      connectionID: connectionID
    )
  }

  private func waitForInFlightStateChangingOperation(
    matching predicate: (MailEngineQualificationEvent) -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
      let events = await factory.events()
      if events.filter(predicate).count == 1 {
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw MailEngineQualificationHarnessError.operationStartTimedOut
  }

  private func assertInFlightStateChangingOperationWasNotReplayed(
    connectionID: String,
    expectsServiceTeardown: Bool = true
  ) async {
    let events = await factory.events()
    let stateChangingEvents = events.filter {
      switch $0 {
      case .copyReceived(let eventConnectionID, _, _, _, _),
        .moveReceived(let eventConnectionID, _, _, _, _),
        .sentAppendReceived(let eventConnectionID, _, _):
        eventConnectionID == connectionID
      default:
        false
      }
    }
    XCTAssertEqual(
      stateChangingEvents.count,
      1,
      "Terminating a transmitted state-changing command must not replay it."
    )
    if expectsServiceTeardown {
      assertServiceTeardownEvents(events, connectionID: connectionID)
    } else {
      await assertNoServiceClose(
        connectionID: connectionID,
        failureMessage: "Task cancellation must preserve the owning connected session."
      )
    }
  }

  private func assertNoSubmissionContentAccepted(connectionID: String) async {
    let eventsAfterClose = await factory.events()
    XCTAssertFalse(
      eventsAfterClose.contains {
        if case .submissionContentAccepted(let eventConnectionID, _) = $0 {
          return eventConnectionID == connectionID
        }
        return false
      },
      "Closing a session before DATA must prevent message-content transmission."
    )
  }

  private func assertSessionRemainsUsable(
    _ session: any MailEngineSession,
    connectionID: String
  ) async throws {
    let metadataLoad = Task {
      try await session.loadMetadataPage(
        mailbox: MailEngineMailboxIdentity("INBOX"),
        beforeUID: nil,
        limit: 1
      )
    }
    guard
      let metadataResult = await boundedResult(
        of: metadataLoad,
        timeoutMessage: "Timed out waiting for follow-up IMAP metadata."
      )
    else {
      return
    }
    _ = try metadataResult.get()
    await assertNoServiceClose(
      connectionID: connectionID,
      failureMessage: "Closing one session must preserve other connected sessions."
    )
  }

  private func assertCloseCompletes(
    _ session: any MailEngineSession,
    connectionID: String
  ) async -> Bool {
    let closeTask = Task<Void, Error> {
      await session.close()
    }
    guard
      let result = await boundedResult(
        of: closeTask,
        timeoutMessage: "Timed out waiting for \(connectionID) to close."
      )
    else {
      return false
    }
    switch result {
    case .success:
      return true
    case .failure(let error):
      XCTFail("Closing \(connectionID) failed: \(error)")
      return false
    }
  }

  private func boundedResult<Success: Sendable>(
    of task: Task<Success, Error>,
    timeoutMessage: String
  ) async -> Result<Success, Error>? {
    let completion = LockedBox<Result<Success, Error>?>(nil)
    let completionObserver = Task {
      let result = await task.result
      completion.withValue { $0 = result }
    }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while completion.value == nil, clock.now < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    guard let result = completion.value else {
      task.cancel()
      completionObserver.cancel()
      XCTFail(timeoutMessage)
      return nil
    }
    return result
  }

  private func assertInFlightOperationClosed(_ task: Task<Void, Error>) async {
    let completion = LockedBox<Result<Void, Error>?>(nil)
    let completionObserver = Task {
      let result = await task.result
      completion.withValue { $0 = result }
    }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while completion.value == nil, clock.now < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    guard let result = completion.value else {
      task.cancel()
      completionObserver.cancel()
      XCTFail("Closing the session must terminate in-flight operations.")
      return
    }
    switch result {
    case .success:
      XCTFail("An in-flight operation must not succeed after session closure.")
    case .failure(let error):
      XCTAssertEqual(error as? MailEngineError, .connectionClosed)
    }
  }

  private func assertTransmittedStateChangingOperationOutcomeUnknown<Success: Sendable>(
    _ task: Task<Success, Error>,
    operation: String,
    termination: String
  ) async {
    let completion = LockedBox<Result<Success, Error>?>(nil)
    let completionObserver = Task {
      let result = await task.result
      completion.withValue { $0 = result }
    }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while completion.value == nil, clock.now < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    guard let result = completion.value else {
      task.cancel()
      completionObserver.cancel()
      XCTFail("\(termination) must terminate an in-flight \(operation).")
      return
    }
    switch result {
    case .success:
      XCTFail("An in-flight \(operation) must not succeed after \(termination.lowercased()).")
    case .failure(let error):
      XCTAssertEqual(
        error as? MailEngineError,
        .operationOutcomeUnknown,
        "A transmitted in-flight \(operation) must report an unknown outcome."
      )
    }
  }

  // swiftlint:disable:next function_body_length
  private func assertClosedOperations(
    _ session: any MailEngineSession,
    connectionID: String
  ) async {
    let inbox = MailEngineMailboxIdentity("INBOX")
    let archive = MailEngineMailboxIdentity("Archive")
    let message = MailEngineMessageIdentity(
      connectionID: connectionID,
      mailbox: inbox,
      uid: 9,
      uidValidity: 44
    )
    await assertClosedOperation("appendToSent") {
      _ = try await session.appendToSent(Data("message".utf8), mailbox: archive)
    }
    await assertClosedOperation("copy") {
      _ = try await session.copy(
        messages: messageIdentities(
          connectionID: connectionID,
          mailbox: inbox,
          uidValidity: 44,
          uids: [9]
        ),
        to: archive
      )
    }
    await assertClosedOperation("fetchBodyParts") {
      _ = try await session.fetchBodyParts([MailEngineBodyPartSelector("1.TEXT")], for: message)
    }
    await assertClosedOperation("idle") {
      try await session.idle(mailbox: inbox) { _ in }
    }
    await assertClosedOperation("loadMetadataPage") {
      _ = try await session.loadMetadataPage(
        mailbox: inbox,
        beforeUID: nil,
        limit: 1
      )
    }
    await assertClosedOperation("move") {
      _ = try await session.move(
        messages: messageIdentities(
          connectionID: connectionID,
          mailbox: inbox,
          uidValidity: 44,
          uids: [9]
        ),
        to: archive
      )
    }
    await assertClosedOperation("submit") {
      _ = try await session.submit(
        envelope: MailEngineEnvelope(
          recipients: ["recipient@example.com"],
          sender: "sender@example.com"
        ),
        rawMessage: Data("message".utf8)
      )
    }
  }

  private func assertServiceTeardownEvents(
    _ events: [MailEngineQualificationEvent],
    connectionID: String = "connection-a"
  ) {
    XCTAssertTrue(
      events.contains(.serviceClosed(connectionID: connectionID, service: .imap))
    )
    XCTAssertTrue(
      events.contains(.serviceClosed(connectionID: connectionID, service: .smtp))
    )
  }

  private func assertClosedOperation(
    _ operationName: String,
    operation: @escaping @Sendable () async throws -> Void
  ) async {
    let operationTask = Task { try await operation() }
    let completion = LockedBox<Result<Void, Error>?>(nil)
    let completionObserver = Task {
      let result = await operationTask.result
      completion.withValue { $0 = result }
    }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while completion.value == nil, clock.now < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    guard let result = completion.value else {
      operationTask.cancel()
      completionObserver.cancel()
      XCTFail("Timed out waiting for closed session to reject \(operationName).")
      return
    }
    switch result {
    case .success:
      XCTFail("A closed session should reject \(operationName).")
    case .failure(let error):
      XCTAssertEqual(error as? MailEngineError, .connectionClosed)
    }
  }

  private func connect(
    fixture: MailEngineQualificationFixture,
    authorization: MailEngineAuthorization = .password(
      username: "private-mailbox@example.com",
      password: "private-password"
    ),
    connectionID: String = "connection-a",
    imapTransportMode: MailEngineTransportMode = .implicitTLS,
    minimumTLSVersion: MailEngineTLSVersion = .tls12,
    smtpTransportMode: MailEngineTransportMode = .implicitTLS
  ) async throws -> (
    snapshot: MailEngineConnectionSnapshot,
    session: any MailEngineSession
  ) {
    try await factory.makeEngine(fixture: fixture).connect(
      configuration: configuration(
        fixture: fixture,
        authorization: authorization,
        connectionID: connectionID,
        imapTransportMode: imapTransportMode,
        minimumTLSVersion: minimumTLSVersion,
        smtpTransportMode: smtpTransportMode
      ),
      logger: PrivacyPreservingMailEngineLogger(sink: RecordingMailEngineProductionLogSink())
    )
  }

  // swiftlint:disable:next function_body_length
  private func assertConnectionFails(
    fixture: MailEngineQualificationFixture,
    authorization: MailEngineAuthorization = .password(
      username: "private-mailbox@example.com",
      password: "private-password"
    ),
    failedService: MailEngineService,
    imapTransportMode: MailEngineTransportMode = .implicitTLS,
    minimumTLSVersion: MailEngineTLSVersion = .tls12,
    smtpTransportMode: MailEngineTransportMode = .implicitTLS,
    expectedError: MailEngineError
  ) async {
    let connectionID = "expected-failure-\(await factory.events().count)"
    do {
      _ = try await factory.makeEngine(fixture: fixture).connect(
        configuration: configuration(
          fixture: fixture,
          authorization: authorization,
          connectionID: connectionID,
          imapTransportMode: imapTransportMode,
          minimumTLSVersion: minimumTLSVersion,
          smtpTransportMode: smtpTransportMode
        ),
        logger: PrivacyPreservingMailEngineLogger(sink: RecordingMailEngineProductionLogSink())
      )
      XCTFail("The candidate should reject this connection.")
    } catch {
      XCTAssertEqual(error as? MailEngineError, expectedError)
    }
    await waitForFailedConnectionSetupQuiescence(connectionID)
    let events = await factory.events()
    let serviceEvents = events.filter { $0.belongs(to: connectionID, service: failedService) }
    if expectedError == .authenticationRejected {
      guard
        case .tlsEstablished(
          connectionID: connectionID,
          service: failedService,
          version: let negotiatedVersion
        ) = serviceEvents.first
      else {
        XCTFail("Secure transport must be established before authentication rejection.")
        return
      }
      XCTAssertGreaterThanOrEqual(negotiatedVersion, .tls12)
      XCTAssertEqual(
        Array(serviceEvents.dropFirst()),
        [
          .authenticationStarted(connectionID: connectionID, service: failedService),
          .serviceClosed(connectionID: connectionID, service: failedService),
        ]
      )
    } else {
      XCTAssertEqual(
        serviceEvents,
        [.serviceClosed(connectionID: connectionID, service: failedService)],
        "Secure setup failures must close the failed service without starting authentication."
      )
    }
    assertOtherServiceCleanup(
      events,
      connectionID: connectionID,
      failedService: failedService
    )
  }

  private func waitForFailedConnectionSetupQuiescence(_ connectionID: String) async {
    do {
      try await factory.waitForConnectionSetupQuiescence(
        connectionID: connectionID,
        timeout: .seconds(2)
      )
    } catch {
      XCTFail("Timed out waiting for failed connection setup to quiesce.")
    }
  }

  private func assertOtherServiceCleanup(
    _ events: [MailEngineQualificationEvent],
    connectionID: String,
    failedService: MailEngineService
  ) {
    let otherService = failedService == .imap ? MailEngineService.smtp : .imap
    let otherServiceEvents = events.filter {
      $0.belongs(to: connectionID, service: otherService)
    }
    let otherServiceWasOpened = otherServiceEvents.contains {
      if case .serviceClosed = $0 {
        return false
      }
      return true
    }
    if otherServiceWasOpened {
      XCTAssertTrue(
        otherServiceEvents.contains(
          .serviceClosed(connectionID: connectionID, service: otherService)
        ),
        "A candidate must close the other service when setup fails after it was opened."
      )
    }
  }

  private func configuration(
    fixture: MailEngineQualificationFixture,
    authorization: MailEngineAuthorization = .password(
      username: "private-mailbox@example.com",
      password: "private-password"
    ),
    connectionID: String = "connection-a",
    imapTransportMode: MailEngineTransportMode = .implicitTLS,
    minimumTLSVersion: MailEngineTLSVersion = .tls12,
    smtpTransportMode: MailEngineTransportMode = .implicitTLS
  ) -> MailEngineConfiguration {
    let base = factory.configuration(
      fixture: fixture,
      authorization: authorization,
      connectionID: connectionID,
      imapTransportMode: imapTransportMode,
      smtpTransportMode: smtpTransportMode
    )
    return MailEngineConfiguration(
      authorization: base.authorization,
      connectionID: base.connectionID,
      imapEndpoint: base.imapEndpoint,
      minimumTLSVersion: minimumTLSVersion,
      smtpEndpoint: base.smtpEndpoint
    )
  }
}

private final class ScriptedMailEngineQualificationFactory:
  MailEngineQualificationCandidateFactory,
  @unchecked Sendable
{
  private let state = ScriptedMailEngineState()

  func configuration(
    fixture _: MailEngineQualificationFixture,
    authorization: MailEngineAuthorization,
    connectionID: String,
    imapTransportMode: MailEngineTransportMode,
    smtpTransportMode: MailEngineTransportMode
  ) -> MailEngineConfiguration {
    MailEngineConfiguration(
      authorization: authorization,
      connectionID: connectionID,
      imapEndpoint: MailEngineEndpoint(
        hostname: "imap.example.com",
        port: imapTransportMode == .implicitTLS ? 993 : 143,
        transportMode: imapTransportMode
      ),
      smtpEndpoint: MailEngineEndpoint(
        hostname: "smtp.example.com",
        port: smtpTransportMode == .implicitTLS ? 465 : 587,
        transportMode: smtpTransportMode
      )
    )
  }

  func events() async -> [MailEngineQualificationEvent] {
    await state.events
  }

  func capturedCandidateLogOutput() async -> Data {
    await state.candidateLogOutput
  }

  func makeEngine(fixture: MailEngineQualificationFixture) -> any MailEngine {
    ScriptedMailEngine(fixture: fixture, state: state)
  }

  func waitForBodyFetchStarts(_ count: Int, timeout: Duration) async throws {
    try await state.waitForBodyFetchStarts(count, timeout: timeout)
  }

  func waitForConnectionSetupQuiescence(
    connectionID: String,
    timeout: Duration
  ) async throws {
    try await state.waitForConnectionSetupQuiescence(
      connectionID: connectionID,
      timeout: timeout
    )
  }

  func waitForClosedSessionQuiescence(
    connectionID: String,
    timeout: Duration
  ) async throws {
    try await state.waitForClosedSessionQuiescence(
      connectionID: connectionID,
      timeout: timeout
    )
  }

  func waitForIdleLateCallbackAttempt(
    connectionID: String,
    timeout: Duration
  ) async throws {
    try await state.waitForIdleLateCallbackAttempt(
      connectionID: connectionID,
      timeout: timeout
    )
  }

  func waitForIdleStarts(_ count: Int, timeout: Duration) async throws {
    try await state.waitForIdleStarts(count, timeout: timeout)
  }

  func waitForSubmissionEnvelopeAccepted(
    connectionID: String,
    timeout: Duration
  ) async throws {
    try await state.waitForSubmissionEnvelopeAccepted(
      connectionID: connectionID,
      timeout: timeout
    )
  }

  func waitForSubmissionContentStarts(
    _ count: Int,
    connectionID: String,
    timeout: Duration
  ) async throws {
    try await state.waitForSubmissionContentStarts(
      count,
      connectionID: connectionID,
      timeout: timeout
    )
  }

  func waitForSubmissionTransportTermination(
    connectionID: String,
    timeout: Duration
  ) async throws {
    try await state.waitForSubmissionTransportTermination(
      connectionID: connectionID,
      timeout: timeout
    )
  }

  func waitForSubmissionStarts(_ count: Int, timeout: Duration) async throws {
    try await state.waitForSubmissionStarts(count, timeout: timeout)
  }

}

private actor ScriptedMailEngineState {
  private(set) var events: [MailEngineQualificationEvent] = []
  private(set) var candidateLogOutput = Data()
  private var closedOperationRejections: [String: Int] = [:]

  func record(_ event: MailEngineQualificationEvent) {
    events.append(event)
  }

  func recordCandidateLogOutput(_ output: Data) {
    candidateLogOutput.append(output)
  }

  func recordClosedOperationRejection(connectionID: String) {
    closedOperationRejections[connectionID, default: 0] += 1
  }

  func waitForBodyFetchStarts(_ count: Int, timeout: Duration) async throws {
    try await waitForEvents(count, timeout: timeout) {
      if case .bodyFetchStarted = $0 { return true }
      return false
    }
  }

  func waitForConnectionSetupQuiescence(
    connectionID: String,
    timeout: Duration
  ) async throws {
    try await waitForEvents(1, timeout: timeout) {
      $0 == .connectionSetupQuiesced(connectionID: connectionID)
    }
  }

  func waitForClosedSessionQuiescence(
    connectionID: String,
    timeout: Duration
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while closedOperationRejections[connectionID, default: 0] < 7 {
      guard clock.now < deadline else {
        throw MailEngineQualificationHarnessError.operationStartTimedOut
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  func waitForIdleLateCallbackAttempt(
    connectionID: String,
    timeout: Duration
  ) async throws {
    try await waitForEvents(1, timeout: timeout) {
      $0 == .idleLateCallbackAttempted(connectionID: connectionID)
    }
  }

  func waitForIdleStarts(_ count: Int, timeout: Duration) async throws {
    try await waitForEvents(count, timeout: timeout) {
      if case .idleStarted = $0 { return true }
      return false
    }
  }

  func waitForSubmissionEnvelopeAccepted(
    connectionID: String,
    timeout: Duration
  ) async throws {
    try await waitForEvents(1, timeout: timeout) {
      if case .submissionEnvelopeAccepted(let eventConnectionID, _) = $0 {
        return eventConnectionID == connectionID
      }
      return false
    }
  }

  func waitForOverlappingCopyStarts(timeout: Duration) async throws {
    try await waitForEvents(2, timeout: timeout) {
      if case .copyReceived(let connectionID, _, _, _, _) = $0 {
        return connectionID == "copy-connection-one" || connectionID == "copy-connection-two"
      }
      return false
    }
  }

  func waitForOverlappingMoveStarts(timeout: Duration) async throws {
    try await waitForEvents(2, timeout: timeout) {
      if case .moveReceived(let connectionID, _, _, _, _) = $0 {
        return connectionID == "move-connection-one" || connectionID == "move-connection-two"
      }
      return false
    }
  }

  func waitForOverlappingMetadataStarts(timeout: Duration) async throws {
    try await waitForEvents(2, timeout: timeout) {
      if case .metadataPageRequested(let connectionID, _, _, _) = $0 {
        return connectionID == "connection-one" || connectionID == "connection-two"
      }
      return false
    }
  }

  func waitForOverlappingBodyResultStarts(timeout: Duration) async throws {
    try await waitForEvents(2, timeout: timeout) {
      if case .bodyPartsRequested(let connectionID, _, _) = $0 {
        return connectionID == "body-result-one" || connectionID == "body-result-two"
      }
      return false
    }
  }

  func waitForOverlappingConnectionSetupStarts(
    service: MailEngineService,
    timeout: Duration
  ) async throws {
    try await waitForEvents(2, timeout: timeout) {
      if case .authenticationStarted(let connectionID, service: let eventService) = $0 {
        return eventService == service
          && (connectionID == "setup-connection-one" || connectionID == "setup-connection-two")
      }
      return false
    }
  }

  func waitForOverlappingSetupSubmissionStarts(timeout: Duration) async throws {
    try await waitForEvents(2, timeout: timeout) {
      if case .submissionStarted(let connectionID) = $0 {
        return connectionID == "setup-connection-one" || connectionID == "setup-connection-two"
      }
      return false
    }
  }

  func waitForOverlappingSentAppendStarts(timeout: Duration) async throws {
    try await waitForEvents(2, timeout: timeout) {
      if case .sentAppendReceived(let connectionID, _, _) = $0 {
        return connectionID == "sent-append-one" || connectionID == "sent-append-two"
      }
      return false
    }
  }

  func waitForSubmissionContentStarts(
    _ count: Int,
    connectionID: String,
    timeout: Duration
  ) async throws {
    try await waitForEvents(count, timeout: timeout) {
      if case .submissionContentAccepted(let eventConnectionID, _) = $0 {
        return eventConnectionID == connectionID
      }
      return false
    }
  }

  func waitForSubmissionStarts(_ count: Int, timeout: Duration) async throws {
    try await waitForEvents(count, timeout: timeout) {
      if case .submissionStarted = $0 { return true }
      return false
    }
  }

  func waitForSubmissionTransportTermination(
    connectionID: String,
    timeout: Duration
  ) async throws {
    try await waitForEvents(1, timeout: timeout) {
      $0 == .submissionTransportTerminated(connectionID: connectionID)
    }
  }

  func waitForOverlappingActiveSubmissionStarts(timeout: Duration) async throws {
    try await waitForEvents(2, timeout: timeout) {
      if case .submissionStarted(let connectionID) = $0 {
        return connectionID == "connection-one" || connectionID == "connection-two"
      }
      return false
    }
  }

  private func waitForEvents(
    _ count: Int,
    timeout: Duration,
    matching predicate: (MailEngineQualificationEvent) -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while events.filter(predicate).count < count {
      guard clock.now < deadline else {
        throw MailEngineQualificationHarnessError.idleStartTimedOut
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}

private enum MailEngineQualificationHarnessError: Error {
  case idleEventTimedOut
  case idleStartTimedOut
  case operationStartTimedOut
}

private struct ScriptedMailEngine: MailEngine {
  let fixture: MailEngineQualificationFixture
  let state: ScriptedMailEngineState

  func connect(
    configuration: MailEngineConfiguration,
    logger: any MailEngineLogging
  ) async throws -> (snapshot: MailEngineConnectionSnapshot, session: any MailEngineSession) {
    logger.recordProtocolTrace(privateProtocolTrace(authorization: configuration.authorization))
    await state.recordCandidateLogOutput(Data([0xFF]) + Data("mail engine connected\n".utf8))

    var transportSecurity: [MailEngineService: MailEngineTLSVersion] = [:]
    do {
      for service in [MailEngineService.imap, .smtp] {
        let negotiatedVersion = try await establish(
          service: service,
          configuration: configuration
        )
        transportSecurity[service] = negotiatedVersion
      }
    } catch {
      for service in transportSecurity.keys {
        await state.record(
          .serviceClosed(connectionID: configuration.connectionID, service: service)
        )
      }
      await state.record(.connectionSetupQuiesced(connectionID: configuration.connectionID))
      throw error
    }

    await state.record(.connectionSetupQuiesced(connectionID: configuration.connectionID))
    logger.record(.connected)

    return (
      snapshot(
        transportSecurity: transportSecurity,
        connectionID: configuration.connectionID
      ),
      ScriptedMailEngineSession(
        authorization: configuration.authorization,
        connectionID: configuration.connectionID,
        fixture: fixture,
        minimumTLSVersion: configuration.minimumTLSVersion,
        state: state
      )
    )
  }

  private func establish(
    service: MailEngineService,
    configuration: MailEngineConfiguration
  ) async throws -> MailEngineTLSVersion {
    try await rejectConfiguredFailure(service: service, configuration: configuration)

    let negotiatedVersion = try await negotiatedVersion(
      service: service,
      configuration: configuration
    )

    await state.record(
      .tlsEstablished(
        connectionID: configuration.connectionID,
        service: service,
        version: negotiatedVersion
      )
    )
    await state.record(
      .authenticationStarted(connectionID: configuration.connectionID, service: service)
    )
    try await waitForOverlappingConnectionSetup(service: service)
    if case .xoauth2Challenge(let challengeService) = fixture,
      challengeService == service
    {
      guard case .xoauth2 = configuration.authorization else {
        throw MailEngineError.authenticationRejected
      }
      await state.record(
        .authenticationChallengeAnswered(
          connectionID: configuration.connectionID,
          service: service
        )
      )
    }
    await state.record(
      .authenticated(connectionID: configuration.connectionID, service: service)
    )
    return negotiatedVersion
  }

  private func negotiatedVersion(
    service: MailEngineService,
    configuration: MailEngineConfiguration
  ) async throws -> MailEngineTLSVersion {
    if case .maximumTLS(let maximumService, let maximumTLSVersion) = fixture,
      maximumService == service
    {
      guard maximumTLSVersion >= configuration.minimumTLSVersion else {
        await state.record(
          .serviceClosed(connectionID: configuration.connectionID, service: service)
        )
        throw MailEngineError.tlsVersionUnsupported
      }
      return maximumTLSVersion
    }
    if case .reducedCapabilityMove = fixture {
      return .tls12
    }
    if case .reducedCapabilityMoveCopyRejected = fixture {
      return .tls12
    }
    if case .reducedCapabilityMoveMalformedCopyUID = fixture {
      return .tls12
    }
    if case .overlappingConnectionSetup = fixture,
      configuration.connectionID == "setup-connection-one"
    {
      return .tls12
    }
    return .tls13
  }

  private func waitForOverlappingConnectionSetup(
    service: MailEngineService
  ) async throws {
    if case .overlappingConnectionSetup = fixture {
      try await state.waitForOverlappingConnectionSetupStarts(
        service: service,
        timeout: .seconds(2)
      )
    }
  }

  private func rejectConfiguredFailure(
    service: MailEngineService,
    configuration: MailEngineConfiguration
  ) async throws {
    if case .startTLSAcknowledgedWithoutUpgrade(let failedService) = fixture,
      failedService == service
    {
      await state.record(
        .serviceClosed(connectionID: configuration.connectionID, service: service)
      )
      throw MailEngineError.startTLSRejected
    }
    if case .connectionFailure(let failedService, let error) = fixture,
      failedService == service
    {
      if error == .authenticationRejected {
        await state.record(
          .tlsEstablished(
            connectionID: configuration.connectionID,
            service: service,
            version: .tls13
          )
        )
        await state.record(
          .authenticationStarted(connectionID: configuration.connectionID, service: service)
        )
      }
      await state.record(
        .serviceClosed(connectionID: configuration.connectionID, service: service)
      )
      throw error
    }
  }

  private func privateProtocolTrace(authorization: MailEngineAuthorization) -> Data {
    let authentication: String
    switch authorization {
    case .password(let username, let password):
      authentication = "LOGIN \(username) \(password)"
    case .xoauth2(let username, let accessToken):
      authentication = "AUTHENTICATE \(username) \(accessToken)"
    }
    return Data(
      """
      \(authentication)
      * LIST () "/" "private-mailbox"
      Subject: private message
      """.utf8
    )
  }

  private func snapshot(
    transportSecurity: [MailEngineService: MailEngineTLSVersion],
    connectionID: String
  ) -> MailEngineConnectionSnapshot {
    var capabilities: Set<MailEngineCapability>
    if case .reducedCapabilityMove(let hasMove, let hasUIDPlus) = fixture {
      capabilities = [.idle, .specialUse]
      if hasMove {
        capabilities.insert(.move)
      }
      if hasUIDPlus {
        capabilities.insert(.uidPlus)
      }
    } else if case .reducedCapabilityMoveCopyRejected = fixture {
      capabilities = [.idle, .specialUse, .uidPlus]
    } else if case .reducedCapabilityMoveMalformedCopyUID = fixture {
      capabilities = [.idle, .specialUse, .uidPlus]
    } else {
      capabilities = [.idle, .move, .specialUse, .uidPlus]
    }
    var mailboxes = [
      MailEngineMailbox(identity: MailEngineMailboxIdentity("INBOX"), specialUses: []),
      MailEngineMailbox(
        identity: MailEngineMailboxIdentity("Transmitted Items"),
        specialUses: [.sent]
      ),
    ]
    if case .reducedCapabilityMove = fixture {
      mailboxes.reverse()
    }
    if case .overlappingConnectionSetup = fixture {
      let sentMailbox =
        connectionID == "setup-connection-one"
        ? MailEngineMailboxIdentity("First Sent")
        : MailEngineMailboxIdentity("Second Sent")
      mailboxes[1] = MailEngineMailbox(identity: sentMailbox, specialUses: [.sent])
      if connectionID == "setup-connection-one" {
        capabilities.remove(.move)
      }
    }
    return MailEngineConnectionSnapshot(
      capabilities: capabilities,
      mailboxes: mailboxes,
      transportSecurity: transportSecurity
    )
  }
}

private struct MailEngineMutationSource {
  let mailbox: MailEngineMailboxIdentity
  let uidValidity: Int64
  let uids: [Int64]
}

private actor ScriptedMailEngineSession: MailEngineSession {
  let authorization: MailEngineAuthorization
  let connectionID: String
  let fixture: MailEngineQualificationFixture
  let minimumTLSVersion: MailEngineTLSVersion
  let state: ScriptedMailEngineState
  private var appendAttempt = 0
  private var uidValidityByMailbox: [MailEngineMailboxIdentity: Int64] = [
    MailEngineMailboxIdentity("INBOX"): 44,
    MailEngineMailboxIdentity("Archive"): 73,
  ]
  private var idleAttempt = 0
  private var isClosed = false
  private var hasUnreconciledMutationOutcome = false
  private var smtpRequiresReauthentication = false
  private var smtpStageIndex = 0

  init(
    authorization: MailEngineAuthorization,
    connectionID: String,
    fixture: MailEngineQualificationFixture,
    minimumTLSVersion: MailEngineTLSVersion,
    state: ScriptedMailEngineState
  ) {
    self.authorization = authorization
    self.connectionID = connectionID
    self.fixture = fixture
    self.minimumTLSVersion = minimumTLSVersion
    self.state = state
  }

  private var waitsForTransmittedMutationTermination: Bool {
    switch fixture {
    case .inFlightOperationsUntilClosed, .stateChangingOperationUntilCancelled:
      true
    default:
      false
    }
  }

  func appendToSent(
    _ rawMessage: Data,
    mailbox: MailEngineMailboxIdentity
  ) async throws -> MailEngineMessageIdentity {
    try await ensureOpen()
    if hasUnreconciledMutationOutcome {
      throw MailEngineError.operationOutcomeUnknown
    }
    appendAttempt += 1
    await state.record(.sentAppend(connectionID: connectionID))
    await state.record(
      .sentAppendReceived(
        connectionID: connectionID,
        mailbox: mailbox,
        rawMessage: rawMessage
      )
    )
    if waitsForTransmittedMutationTermination {
      try await waitForTransmittedMutationTermination()
    }
    if case .sentAppendOutcomeUnknown = fixture {
      hasUnreconciledMutationOutcome = true
      throw MailEngineError.operationOutcomeUnknown
    }
    if case .sentAppendFailsOnce = fixture, appendAttempt == 1 {
      throw MailEngineError.protocolRejected(code: "TRYAGAIN", retryable: true)
    }
    if case .sentAppendPermanentlyRejected = fixture {
      throw MailEngineError.protocolRejected(code: "NOPERM", retryable: false)
    }
    if case .missingSentAppendIdentity = fixture {
      throw MailEngineUIDMappingError.invalidUID
    }
    if case .overlappingSentAppend = fixture {
      try await state.waitForOverlappingSentAppendStarts(timeout: .seconds(2))
    }
    let identity = sentAppendIdentity(mailbox: mailbox)
    try validateSentAppendIdentity(identity)
    return identity
  }

  private func sentAppendIdentity(
    mailbox: MailEngineMailboxIdentity
  ) -> MailEngineMessageIdentity {
    let uid: Int64
    let uidValidity: Int64
    switch fixture {
    case .invalidSentAppendIdentity(let fixtureUID, let fixtureUIDValidity):
      uid = fixtureUID
      uidValidity = fixtureUIDValidity
    case .overlappingSentAppend(let fixtureUID, let fixtureUIDValidity):
      uid = fixtureUID
      uidValidity = fixtureUIDValidity
    default:
      uid = 11
      uidValidity = 45
    }
    return MailEngineMessageIdentity(
      connectionID: connectionID,
      mailbox: mailbox,
      uid: uid,
      uidValidity: uidValidity
    )
  }

  private func validateSentAppendIdentity(
    _ identity: MailEngineMessageIdentity
  ) throws {
    guard (1...4_294_967_295).contains(identity.uidValidity) else {
      throw MailEngineUIDMappingError.invalidSourceUIDValidity
    }
    guard (1...4_294_967_295).contains(identity.uid) else {
      throw MailEngineUIDMappingError.invalidUID
    }
    guard identity.connectionID == connectionID else {
      throw MailEngineError.staleMessageIdentity
    }
  }

  private func mutationSource(
    _ messages: [MailEngineMessageIdentity]
  ) throws -> MailEngineMutationSource {
    guard let first = messages.first else {
      throw MailEngineUIDMappingError.invalidUID
    }
    guard messages.allSatisfy({ $0.connectionID == connectionID }) else {
      throw MailEngineError.staleMessageIdentity
    }
    guard
      messages.allSatisfy({
        $0.mailbox == first.mailbox && $0.uidValidity == first.uidValidity
      })
    else {
      throw MailEngineError.staleMessageIdentity
    }
    return MailEngineMutationSource(
      mailbox: first.mailbox,
      uidValidity: first.uidValidity,
      uids: messages.map(\.uid)
    )
  }

  func close() async {
    isClosed = true
    await state.record(.serviceClosed(connectionID: connectionID, service: .imap))
    await state.record(.serviceClosed(connectionID: connectionID, service: .smtp))
    await state.record(.closed(connectionID: connectionID))
  }

  func copy(
    messages: [MailEngineMessageIdentity],
    to destinationMailbox: MailEngineMailboxIdentity
  ) async throws -> MailEngineUIDMapping {
    try await ensureOpen()
    if hasUnreconciledMutationOutcome {
      throw MailEngineError.operationOutcomeUnknown
    }
    let source = try mutationSource(messages)
    let sourceMailbox = source.mailbox
    let sourceUIDValidity = source.uidValidity
    let sourceUIDs = source.uids
    guard (1...4_294_967_295).contains(sourceUIDValidity) else {
      throw MailEngineUIDMappingError.invalidSourceUIDValidity
    }
    guard sourceUIDValidity == uidValidity(for: sourceMailbox) else {
      throw MailEngineError.staleMessageIdentity
    }
    await state.record(
      .copyReceived(
        connectionID: connectionID,
        sourceUIDs: sourceUIDs,
        sourceUIDValidity: sourceUIDValidity,
        sourceMailbox: sourceMailbox,
        destinationMailbox: destinationMailbox
      )
    )
    if waitsForTransmittedMutationTermination {
      try await waitForTransmittedMutationTermination()
    }
    if case .overlappingCopyResults = fixture {
      try await state.waitForOverlappingCopyStarts(timeout: .seconds(2))
    }
    if case .copyOutcomeUnknown = fixture {
      hasUnreconciledMutationOutcome = true
      throw MailEngineError.operationOutcomeUnknown
    }
    if case .copyPermanentlyRejected = fixture {
      throw MailEngineError.protocolRejected(code: "NOPERM", retryable: false)
    }
    if case .copyRetryablyRejected = fixture {
      throw MailEngineError.protocolRejected(code: "TRYAGAIN", retryable: true)
    }
    let reported = reportedCopyUIDMapping(sourceUIDs: sourceUIDs)
    return try MailEngineUIDMapping.validated(
      sourceMailbox: sourceMailbox,
      sourceUIDValidity: sourceUIDValidity,
      destinationMailbox: destinationMailbox,
      requestedSourceUIDs: sourceUIDs,
      reported: reported
    )
  }

  private func reportedCopyUIDMapping(
    sourceUIDs: [Int64]
  ) -> MailEngineReportedUIDMapping {
    if case .emptyUIDMapping = fixture {
      return emptyReportedUIDMapping(destinationUIDValidity: 91)
    }
    if case .malformedCopyUIDMapping = fixture {
      return MailEngineReportedUIDMapping(
        destinationUIDValidity: 91,
        destinationUIDs: [104],
        sourceUIDs: [4]
      )
    }
    if let mapping = repeatedCopyUIDMapping(sourceUIDs: sourceUIDs) {
      return mapping
    }
    if case .mismatchedUIDMappingCardinality = fixture {
      return MailEngineReportedUIDMapping(
        destinationUIDValidity: 91,
        destinationUIDs: [104],
        sourceUIDs: sourceUIDs
      )
    }
    if case .invalidDestinationUIDMapping(let uid) = fixture {
      return MailEngineReportedUIDMapping(
        destinationUIDValidity: 91,
        destinationUIDs: [uid, 105],
        sourceUIDs: sourceUIDs
      )
    }
    if case .invalidSourceUIDMapping(let uid) = fixture {
      return MailEngineReportedUIDMapping(
        destinationUIDValidity: 91,
        destinationUIDs: sourceUIDs.map { $0 + 100 },
        sourceUIDs: [uid, 5]
      )
    }
    if case .invalidUIDValidityMapping(let uidValidity) = fixture {
      return MailEngineReportedUIDMapping(
        destinationUIDValidity: uidValidity,
        destinationUIDs: sourceUIDs.map { $0 + 100 },
        sourceUIDs: sourceUIDs
      )
    }
    let reportedSourceUIDs = Array(sourceUIDs.reversed())
    return MailEngineReportedUIDMapping(
      destinationUIDValidity: 91,
      destinationUIDs: reportedSourceUIDs.map { $0 + 100 },
      sourceUIDs: reportedSourceUIDs
    )
  }

  private func repeatedCopyUIDMapping(
    sourceUIDs: [Int64]
  ) -> MailEngineReportedUIDMapping? {
    if case .repeatedDestinationUIDMapping = fixture {
      return MailEngineReportedUIDMapping(
        destinationUIDValidity: 91,
        destinationUIDs: [104, 104],
        sourceUIDs: sourceUIDs
      )
    }
    if case .repeatedSourceUIDMapping = fixture {
      return MailEngineReportedUIDMapping(
        destinationUIDValidity: 91,
        destinationUIDs: [104, 105],
        sourceUIDs: [4, 4]
      )
    }
    return nil
  }

  func fetchBodyParts(
    _ selectors: Set<MailEngineBodyPartSelector>,
    for message: MailEngineMessageIdentity
  ) async throws -> [MailEngineBodyPart] {
    try await ensureOpen()
    guard message.connectionID == connectionID,
      message.uidValidity == uidValidity(for: message.mailbox)
    else {
      throw MailEngineError.staleMessageIdentity
    }
    await state.record(
      .bodyPartsRequested(
        connectionID: connectionID,
        message: message,
        selectors: selectors
      )
    )
    if case .bodyFetchUntilCancelled = fixture {
      try await waitForBodyFetchTermination()
    }
    if case .overlappingBodyResults = fixture {
      try await state.waitForOverlappingBodyResultStarts(timeout: .seconds(2))
    }
    if case .inFlightOperationsUntilClosed = fixture {
      try await waitForBodyFetchTermination()
    }
    return selectors.sorted { $0.rawValue < $1.rawValue }.map {
      MailEngineBodyPart(
        data: Data(
          "\(message.mailbox.rawValue)-\(message.uidValidity)-\(message.uid)-\($0.rawValue)".utf8
        ),
        selector: $0
      )
    }
  }

  private func waitForBodyFetchTermination() async throws {
    await state.record(.bodyFetchStarted(connectionID: connectionID))
    do {
      while true {
        try await ensureOpen()
        try Task.checkCancellation()
        try await Task.sleep(for: .milliseconds(10))
      }
    } catch is CancellationError {
      await state.record(.bodyFetchCancelled(connectionID: connectionID))
      throw MailEngineError.cancelled
    }
  }

  func idle(
    mailbox: MailEngineMailboxIdentity,
    onEvent: @escaping @Sendable (MailEngineIdleEvent) async -> Void
  ) async throws {
    try await ensureOpen()
    idleAttempt += 1
    if try await handleIDLERecovery(mailbox: mailbox, onEvent: onEvent) {
      return
    }
    await state.record(.idleStarted(connectionID: connectionID, mailbox: mailbox))
    if try await handleInvalidIDLEEvent(onEvent: onEvent) {
      return
    }
    if case .idleUntilCancelled = fixture {
      let event = MailEngineIdleEvent.changedUIDs([metadataUIDs()[0]])
      await onEvent(event)
      await state.record(.idleEventDelivered(connectionID: connectionID, event: event))
      try await waitForIdleCancellation()
    }
    if case .overlappingSMTP = fixture {
      let event = MailEngineIdleEvent.changedUIDs([metadataUIDs()[0]])
      await onEvent(event)
      await state.record(.idleEventDelivered(connectionID: connectionID, event: event))
      try await waitForIdleCancellation()
    }
    if case .inFlightOperationsUntilClosed = fixture {
      let event = MailEngineIdleEvent.changedUIDs([metadataUIDs()[0]])
      await onEvent(event)
      await state.record(.idleEventDelivered(connectionID: connectionID, event: event))
      try await waitForIdleCancellation()
    }
    if case .uidValidityReset = fixture {
      uidValidityByMailbox[mailbox] = 99
      let event = MailEngineIdleEvent.mailboxReset(uidValidity: 99)
      await onEvent(event)
      await state.record(.idleEventDelivered(connectionID: connectionID, event: event))
      try await waitForIdleCancellation()
    }
  }

  private func handleIDLERecovery(
    mailbox: MailEngineMailboxIdentity,
    onEvent: @escaping @Sendable (MailEngineIdleEvent) async -> Void
  ) async throws -> Bool {
    switch fixture {
    case .idleDisconnectThenRecover(
      let maximumReconnectTLSVersion,
      let requiresXOAUTH2Challenge
    ):
      return try await recoverIDLE(
        mailbox: mailbox,
        maximumTLSVersion: maximumReconnectTLSVersion,
        requiresXOAUTH2Challenge: requiresXOAUTH2Challenge,
        onEvent: onEvent
      )
    case .idleDisconnectThenRejectAuthentication(let requiresXOAUTH2Challenge):
      try await rejectIDLERecoveryAuthentication(
        mailbox: mailbox,
        requiresXOAUTH2Challenge: requiresXOAUTH2Challenge
      )
    case .idleDisconnectThenUnsecuredSTARTTLS:
      guard idleAttempt > 1 else {
        await state.record(.idleStarted(connectionID: connectionID, mailbox: mailbox))
        await state.record(.serviceClosed(connectionID: connectionID, service: .imap))
        throw MailEngineError.connectionClosed
      }
      await state.record(.idleLateCallbackAttempted(connectionID: connectionID))
      await state.record(.serviceClosed(connectionID: connectionID, service: .imap))
      throw MailEngineError.startTLSRejected
    case .idleDisconnectThenRejectRecovery(let error):
      guard idleAttempt > 1 else {
        await state.record(.idleStarted(connectionID: connectionID, mailbox: mailbox))
        await state.record(.serviceClosed(connectionID: connectionID, service: .imap))
        throw MailEngineError.connectionClosed
      }
      await state.record(.idleLateCallbackAttempted(connectionID: connectionID))
      await state.record(.serviceClosed(connectionID: connectionID, service: .imap))
      throw error
    default:
      return false
    }
  }

  private func recoverIDLE(
    mailbox: MailEngineMailboxIdentity,
    maximumTLSVersion: MailEngineTLSVersion?,
    requiresXOAUTH2Challenge: Bool,
    onEvent: @escaping @Sendable (MailEngineIdleEvent) async -> Void
  ) async throws -> Bool {
    try await beginIDLERecovery(mailbox: mailbox)
    if let maximumTLSVersion, maximumTLSVersion < minimumTLSVersion {
      await state.record(.idleLateCallbackAttempted(connectionID: connectionID))
      await state.record(.serviceClosed(connectionID: connectionID, service: .imap))
      throw MailEngineError.tlsVersionUnsupported
    }
    await state.record(
      .tlsEstablished(
        connectionID: connectionID,
        service: .imap,
        version: maximumTLSVersion ?? .tls13
      )
    )
    await state.record(.authenticationStarted(connectionID: connectionID, service: .imap))
    try await answerXOAUTH2ChallengeIfRequired(requiresXOAUTH2Challenge)
    await state.record(.authenticated(connectionID: connectionID, service: .imap))
    await state.record(.idleStarted(connectionID: connectionID, mailbox: mailbox))
    let event = MailEngineIdleEvent.changedUIDs([10])
    await onEvent(event)
    await state.record(.idleEventDelivered(connectionID: connectionID, event: event))
    try await waitForIdleCancellation()
    return true
  }

  private func rejectIDLERecoveryAuthentication(
    mailbox: MailEngineMailboxIdentity,
    requiresXOAUTH2Challenge: Bool
  ) async throws -> Never {
    try await beginIDLERecovery(mailbox: mailbox)
    await state.record(
      .tlsEstablished(connectionID: connectionID, service: .imap, version: .tls13)
    )
    await state.record(.authenticationStarted(connectionID: connectionID, service: .imap))
    try await answerXOAUTH2ChallengeIfRequired(requiresXOAUTH2Challenge)
    await state.record(.idleLateCallbackAttempted(connectionID: connectionID))
    await state.record(.serviceClosed(connectionID: connectionID, service: .imap))
    throw MailEngineError.authenticationRejected
  }

  private func beginIDLERecovery(mailbox: MailEngineMailboxIdentity) async throws {
    guard idleAttempt > 1 else {
      await state.record(.idleStarted(connectionID: connectionID, mailbox: mailbox))
      await state.record(.serviceClosed(connectionID: connectionID, service: .imap))
      throw MailEngineError.connectionClosed
    }
  }

  private func answerXOAUTH2ChallengeIfRequired(_ isRequired: Bool) async throws {
    guard isRequired else { return }
    guard case .xoauth2 = authorization else {
      await state.record(.serviceClosed(connectionID: connectionID, service: .imap))
      throw MailEngineError.authenticationRejected
    }
    await state.record(
      .authenticationChallengeAnswered(connectionID: connectionID, service: .imap)
    )
  }

  private func handleInvalidIDLEEvent(
    onEvent: @escaping @Sendable (MailEngineIdleEvent) async -> Void
  ) async throws -> Bool {
    if case .invalidIdleChangedUID(let uid) = fixture {
      let changedUIDs = [Int64(10), uid]
      guard changedUIDs.allSatisfy({ (1...4_294_967_295).contains($0) }) else {
        throw MailEngineUIDMappingError.invalidUID
      }
      let event = MailEngineIdleEvent.changedUIDs(changedUIDs)
      await onEvent(event)
      await state.record(.idleEventDelivered(connectionID: connectionID, event: event))
      return true
    }
    if case .invalidIdleResetUIDValidity(let uidValidity) = fixture {
      guard (1...4_294_967_295).contains(uidValidity) else {
        throw MailEngineUIDMappingError.invalidSourceUIDValidity
      }
      let event = MailEngineIdleEvent.mailboxReset(uidValidity: uidValidity)
      await onEvent(event)
      await state.record(.idleEventDelivered(connectionID: connectionID, event: event))
      return true
    }
    return false
  }

  func loadMetadataPage(
    mailbox: MailEngineMailboxIdentity,
    beforeUID: Int64?,
    limit: Int
  ) async throws -> MailEngineMetadataPage {
    try await ensureOpen()
    await state.record(
      .metadataPageRequested(
        connectionID: connectionID,
        mailbox: mailbox,
        beforeUID: beforeUID,
        limit: limit
      )
    )
    if connectionID == "connection-one" || connectionID == "connection-two" {
      try await state.waitForOverlappingMetadataStarts(timeout: .seconds(2))
    }
    let page = makeMetadataPage(mailbox: mailbox, beforeUID: beforeUID, limit: limit)
    try validateMetadataPage(page)
    return page
  }

  private func makeMetadataPage(
    mailbox: MailEngineMailboxIdentity,
    beforeUID: Int64?,
    limit: Int
  ) -> MailEngineMetadataPage {
    let rawUIDs =
      if case .invalidMetadataUID(let uid) = fixture {
        [9, uid]
      } else {
        metadataUIDs()
      }
    let availableUIDs = rawUIDs.filter { uid in
      beforeUID.map { uid < $0 } ?? true
    }
    let selectedUIDs = Array(availableUIDs.prefix(limit))
    let hasMore = availableUIDs.count > selectedUIDs.count
    let pageUIDValidity =
      if case .invalidMetadataPageUIDValidity(let uidValidity) = fixture {
        uidValidity
      } else {
        uidValidity(for: mailbox)
      }
    let nextOlderUID =
      if case .invalidMetadataNextOlderUID(let uid) = fixture {
        uid
      } else {
        hasMore ? selectedUIDs.last : nil
      }
    return MailEngineMetadataPage(
      messages: selectedUIDs.enumerated().map { index, uid in
        let messageUIDValidity =
          if case .invalidMetadataMessageUIDValidity(let uidValidity) = fixture,
            index > 0
          {
            uidValidity
          } else if case .mismatchedMetadataUIDValidity = fixture {
            pageUIDValidity + 1
          } else {
            pageUIDValidity
          }
        return MailEngineMessageMetadata(
          flags: metadataFlags(for: uid),
          identity: MailEngineMessageIdentity(
            connectionID: connectionID,
            mailbox: mailbox,
            uid: uid,
            uidValidity: messageUIDValidity
          ),
          internalDate: Date(timeIntervalSince1970: TimeInterval(uid)),
          rfcMessageID: "<\(uid)@example.com>"
        )
      },
      nextOlderUID: nextOlderUID,
      uidValidity: pageUIDValidity
    )
  }

  private func validateMetadataPage(_ page: MailEngineMetadataPage) throws {
    guard (1...4_294_967_295).contains(page.uidValidity),
      page.messages.allSatisfy({
        $0.identity.connectionID == connectionID
          && (1...4_294_967_295).contains($0.identity.uidValidity)
          && $0.identity.uidValidity == page.uidValidity
      })
    else {
      throw MailEngineUIDMappingError.invalidSourceUIDValidity
    }
    guard
      page.messages.allSatisfy({ (1...4_294_967_295).contains($0.identity.uid) }),
      page.nextOlderUID.map({ (1...4_294_967_295).contains($0) }) ?? true
    else {
      throw MailEngineUIDMappingError.invalidUID
    }
  }

  func move(
    messages: [MailEngineMessageIdentity],
    to destinationMailbox: MailEngineMailboxIdentity
  ) async throws -> MailEngineUIDMapping {
    try await ensureOpen()
    if hasUnreconciledMutationOutcome {
      throw MailEngineError.operationOutcomeUnknown
    }
    let source = try mutationSource(messages)
    let sourceMailbox = source.mailbox
    let sourceUIDValidity = source.uidValidity
    let sourceUIDs = source.uids
    if case .reducedCapabilityMove(hasMove: false, hasUIDPlus: false) = fixture {
      throw MailEngineError.operationUnsupported
    }
    guard (1...4_294_967_295).contains(sourceUIDValidity) else {
      throw MailEngineUIDMappingError.invalidSourceUIDValidity
    }
    guard sourceUIDValidity == uidValidity(for: sourceMailbox) else {
      throw MailEngineError.staleMessageIdentity
    }
    await recordMoveMutation(
      sourceUIDs: sourceUIDs,
      sourceUIDValidity: sourceUIDValidity,
      sourceMailbox: sourceMailbox,
      destinationMailbox: destinationMailbox
    )
    try throwReducedCapabilityCopyFailure()
    if waitsForTransmittedMutationTermination {
      try await waitForTransmittedMutationTermination()
    }
    if case .overlappingMoveResults = fixture {
      try await state.waitForOverlappingMoveStarts(timeout: .seconds(2))
    }
    let mapping = try validatedMoveMapping(
      sourceUIDs: sourceUIDs,
      sourceUIDValidity: sourceUIDValidity,
      sourceMailbox: sourceMailbox,
      destinationMailbox: destinationMailbox
    )
    await recordReducedCapabilityRemoval(sourceUIDs: sourceUIDs)
    try throwConfiguredMoveFailure()
    return mapping
  }

  private func recordReducedCapabilityRemoval(sourceUIDs: [Int64]) async {
    if case .reducedCapabilityMove = fixture {
      if case .reducedCapabilityMove(hasMove: false, hasUIDPlus: true) = fixture {
        await state.record(
          .moveRemovedSourceUIDs(connectionID: connectionID, uids: sourceUIDs)
        )
      }
      await state.record(
        .movePreservedUnrelatedDeletedUIDs(connectionID: connectionID, uids: [6])
      )
    }
    if case .reducedCapabilityMoveMalformedCopyUID = fixture {
      await state.record(
        .moveRemovedSourceUIDs(connectionID: connectionID, uids: sourceUIDs)
      )
    }
  }

  private func throwConfiguredMoveFailure() throws {
    if case .moveOutcomeUnknown = fixture {
      hasUnreconciledMutationOutcome = true
      throw MailEngineError.operationOutcomeUnknown
    }
    if case .movePermanentlyRejected = fixture {
      throw MailEngineError.protocolRejected(code: "NOPERM", retryable: false)
    }
    if case .moveRetryablyRejected = fixture {
      throw MailEngineError.protocolRejected(code: "TRYAGAIN", retryable: true)
    }
  }

  private func throwReducedCapabilityCopyFailure() throws {
    guard case .reducedCapabilityMoveCopyRejected(let retryable) = fixture else {
      return
    }
    throw MailEngineError.protocolRejected(
      code: retryable ? "TRYAGAIN" : "NOPERM",
      retryable: retryable
    )
  }

  private func waitForSessionClose() async throws {
    while !isClosed {
      try await Task.sleep(for: .milliseconds(10))
    }
    throw MailEngineError.connectionClosed
  }

  private func waitForTransmittedMutationTermination() async throws -> Never {
    do {
      while !isClosed {
        try Task.checkCancellation()
        try await Task.sleep(for: .milliseconds(10))
      }
    } catch is CancellationError {
      throw MailEngineError.operationOutcomeUnknown
    }
    throw MailEngineError.operationOutcomeUnknown
  }

  private func validatedMoveMapping(
    sourceUIDs: [Int64],
    sourceUIDValidity: Int64,
    sourceMailbox: MailEngineMailboxIdentity,
    destinationMailbox: MailEngineMailboxIdentity
  ) throws -> MailEngineUIDMapping {
    try MailEngineUIDMapping.validated(
      sourceMailbox: sourceMailbox,
      sourceUIDValidity: sourceUIDValidity,
      destinationMailbox: destinationMailbox,
      requestedSourceUIDs: sourceUIDs,
      reported: reportedMoveUIDMapping(sourceUIDs: sourceUIDs)
    )
  }

  private func recordMoveMutation(
    sourceUIDs: [Int64],
    sourceUIDValidity: Int64,
    sourceMailbox: MailEngineMailboxIdentity,
    destinationMailbox: MailEngineMailboxIdentity
  ) async {
    if case .reducedCapabilityMove(hasMove: false, hasUIDPlus: true) = fixture {
      await state.record(
        .copyReceived(
          connectionID: connectionID,
          sourceUIDs: sourceUIDs,
          sourceUIDValidity: sourceUIDValidity,
          sourceMailbox: sourceMailbox,
          destinationMailbox: destinationMailbox
        )
      )
    } else if case .reducedCapabilityMoveCopyRejected = fixture {
      await state.record(
        .copyReceived(
          connectionID: connectionID,
          sourceUIDs: sourceUIDs,
          sourceUIDValidity: sourceUIDValidity,
          sourceMailbox: sourceMailbox,
          destinationMailbox: destinationMailbox
        )
      )
    } else if case .reducedCapabilityMoveMalformedCopyUID = fixture {
      await state.record(
        .copyReceived(
          connectionID: connectionID,
          sourceUIDs: sourceUIDs,
          sourceUIDValidity: sourceUIDValidity,
          sourceMailbox: sourceMailbox,
          destinationMailbox: destinationMailbox
        )
      )
    } else {
      await state.record(
        .moveReceived(
          connectionID: connectionID,
          sourceUIDs: sourceUIDs,
          sourceUIDValidity: sourceUIDValidity,
          sourceMailbox: sourceMailbox,
          destinationMailbox: destinationMailbox
        )
      )
    }
  }

  private func reportedMoveUIDMapping(
    sourceUIDs: [Int64]
  ) -> MailEngineReportedUIDMapping {
    if case .emptyUIDMapping = fixture {
      return emptyReportedUIDMapping(destinationUIDValidity: 92)
    }
    if case .malformedCopyUIDMapping = fixture {
      return MailEngineReportedUIDMapping(
        destinationUIDValidity: 92,
        destinationUIDs: [204],
        sourceUIDs: [4]
      )
    }
    if case .reducedCapabilityMoveMalformedCopyUID(let malformed) = fixture {
      return reducedCapabilityMalformedMapping(
        malformed,
        sourceUIDs: sourceUIDs
      )
    }
    if case .repeatedDestinationUIDMapping = fixture {
      return MailEngineReportedUIDMapping(
        destinationUIDValidity: 92,
        destinationUIDs: [204, 204],
        sourceUIDs: sourceUIDs
      )
    }
    if case .repeatedSourceUIDMapping = fixture {
      return MailEngineReportedUIDMapping(
        destinationUIDValidity: 92,
        destinationUIDs: [204, 205],
        sourceUIDs: [4, 4]
      )
    }
    if let invalidMapping = reportedInvalidMoveUIDMapping(sourceUIDs: sourceUIDs) {
      return invalidMapping
    }
    if case .mismatchedUIDMappingCardinality = fixture {
      return MailEngineReportedUIDMapping(
        destinationUIDValidity: 92,
        destinationUIDs: [204],
        sourceUIDs: sourceUIDs
      )
    }
    let reportedSourceUIDs = Array(sourceUIDs.reversed())
    return MailEngineReportedUIDMapping(
      destinationUIDValidity: 92,
      destinationUIDs: reportedSourceUIDs.map { $0 + 200 },
      sourceUIDs: reportedSourceUIDs
    )
  }

  private func emptyReportedUIDMapping(
    destinationUIDValidity: Int64
  ) -> MailEngineReportedUIDMapping {
    MailEngineReportedUIDMapping(
      destinationUIDValidity: destinationUIDValidity,
      destinationUIDs: [],
      sourceUIDs: []
    )
  }

  private func reducedCapabilityMalformedMapping(
    _ malformed: ReducedCapabilityMalformedCopyUID,
    sourceUIDs: [Int64]
  ) -> MailEngineReportedUIDMapping {
    switch malformed {
    case .empty:
      emptyReportedUIDMapping(destinationUIDValidity: 92)
    case .invalidDestinationUID(let uid):
      MailEngineReportedUIDMapping(
        destinationUIDValidity: 92,
        destinationUIDs: [uid, 205],
        sourceUIDs: sourceUIDs
      )
    case .invalidDestinationUIDValidity(let uidValidity):
      MailEngineReportedUIDMapping(
        destinationUIDValidity: uidValidity,
        destinationUIDs: [204, 205],
        sourceUIDs: sourceUIDs
      )
    case .invalidSourceUID(let uid):
      MailEngineReportedUIDMapping(
        destinationUIDValidity: 92,
        destinationUIDs: [204, 205],
        sourceUIDs: [uid, 5]
      )
    case .mismatchedCardinality:
      MailEngineReportedUIDMapping(
        destinationUIDValidity: 92,
        destinationUIDs: [204],
        sourceUIDs: sourceUIDs
      )
    case .mismatchedSourceUIDs:
      MailEngineReportedUIDMapping(
        destinationUIDValidity: 92,
        destinationUIDs: [204],
        sourceUIDs: [4]
      )
    case .repeatedDestinationUID:
      MailEngineReportedUIDMapping(
        destinationUIDValidity: 92,
        destinationUIDs: [204, 204],
        sourceUIDs: sourceUIDs
      )
    case .repeatedSourceUID:
      MailEngineReportedUIDMapping(
        destinationUIDValidity: 92,
        destinationUIDs: [204, 205],
        sourceUIDs: [4, 4]
      )
    }
  }

  private func reportedInvalidMoveUIDMapping(
    sourceUIDs: [Int64]
  ) -> MailEngineReportedUIDMapping? {
    if case .invalidDestinationUIDMapping(let uid) = fixture {
      return MailEngineReportedUIDMapping(
        destinationUIDValidity: 92,
        destinationUIDs: [uid, 205],
        sourceUIDs: sourceUIDs
      )
    }
    if case .invalidSourceUIDMapping(let uid) = fixture {
      return MailEngineReportedUIDMapping(
        destinationUIDValidity: 92,
        destinationUIDs: sourceUIDs.map { $0 + 200 },
        sourceUIDs: [uid, 5]
      )
    }
    if case .invalidUIDValidityMapping(let uidValidity) = fixture {
      return MailEngineReportedUIDMapping(
        destinationUIDValidity: uidValidity,
        destinationUIDs: sourceUIDs.map { $0 + 200 },
        sourceUIDs: sourceUIDs
      )
    }
    return nil
  }

  func submit(
    envelope: MailEngineEnvelope,
    rawMessage: Data
  ) async throws -> MailEngineSMTPOutcome {
    try await ensureOpen()
    try await reauthenticateSMTPIfNeeded()
    if case .smtpCancellationReconnectMaximumTLS12 = fixture {
      defer { smtpStageIndex += 1 }
      let stage: MailEngineSMTPStage =
        smtpStageIndex == 0
        ? .cancelledAfterSenderAccepted
        : .accepted(serverMessageID: "smtp-message-1")
      return try await submitSMTPStage(
        stage,
        envelope: envelope,
        rawMessage: rawMessage
      )
    }
    if case .smtpStages(let stages) = fixture, smtpStageIndex < stages.count {
      defer { smtpStageIndex += 1 }
      return try await submitSMTPStage(
        stages[smtpStageIndex],
        envelope: envelope,
        rawMessage: rawMessage
      )
    }
    if case .overlappingConnectionSetup = fixture {
      return try await submitOverlappingConnectionSetup(
        envelope: envelope,
        rawMessage: rawMessage
      )
    }
    if case .inFlightOperationsUntilClosed = fixture {
      return try await waitForClosedSubmission()
    }
    if case .overlappingSMTP(let serverMessageID) = fixture {
      return try await submitOverlappingSMTP(
        serverMessageID: serverMessageID,
        envelope: envelope,
        rawMessage: rawMessage
      )
    }
    return await recordAcceptedSubmission(
      envelope: envelope,
      rawMessage: rawMessage,
      serverMessageID: "smtp-message-1"
    )
  }

  private func reauthenticateSMTPIfNeeded() async throws {
    guard smtpRequiresReauthentication else { return }
    smtpRequiresReauthentication = false
    let negotiatedVersion: MailEngineTLSVersion =
      if case .smtpCancellationReconnectMaximumTLS12 = fixture {
        .tls12
      } else {
        .tls13
      }
    guard negotiatedVersion >= minimumTLSVersion else {
      await state.record(.serviceClosed(connectionID: connectionID, service: .smtp))
      throw MailEngineError.tlsVersionUnsupported
    }
    await state.record(
      .tlsEstablished(
        connectionID: connectionID,
        service: .smtp,
        version: negotiatedVersion
      )
    )
    await state.record(.authenticationStarted(connectionID: connectionID, service: .smtp))
    await state.record(.authenticated(connectionID: connectionID, service: .smtp))
  }

  private func submitOverlappingConnectionSetup(
    envelope: MailEngineEnvelope,
    rawMessage: Data
  ) async throws -> MailEngineSMTPOutcome {
    await state.record(.submissionStarted(connectionID: connectionID))
    try await state.waitForOverlappingSetupSubmissionStarts(timeout: .seconds(2))
    let serverMessageID =
      connectionID == "setup-connection-one"
      ? "setup-smtp-message-1"
      : "setup-smtp-message-2"
    return await recordAcceptedSubmission(
      envelope: envelope,
      rawMessage: rawMessage,
      serverMessageID: serverMessageID
    )
  }

  private func submitOverlappingSMTP(
    serverMessageID: String,
    envelope: MailEngineEnvelope,
    rawMessage: Data
  ) async throws -> MailEngineSMTPOutcome {
    await state.record(.submissionStarted(connectionID: connectionID))
    try await state.waitForOverlappingActiveSubmissionStarts(timeout: .seconds(2))
    return await recordAcceptedSubmission(
      envelope: envelope,
      rawMessage: rawMessage,
      serverMessageID: serverMessageID
    )
  }

  private func waitForClosedSubmission() async throws -> MailEngineSMTPOutcome {
    await state.record(.submissionStarted(connectionID: connectionID))
    while true {
      try await ensureOpen()
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func recordAcceptedSubmission(
    envelope: MailEngineEnvelope,
    rawMessage: Data,
    serverMessageID: String
  ) async -> MailEngineSMTPOutcome {
    await state.record(.submitted(connectionID: connectionID))
    await state.record(
      .submissionReceived(
        connectionID: connectionID,
        envelope: envelope,
        rawMessage: rawMessage
      )
    )
    await state.record(
      .submissionContentAccepted(connectionID: connectionID, rawMessage: rawMessage)
    )
    return .accepted(serverMessageID: serverMessageID)
  }

  private func submitSMTPStage(
    _ stage: MailEngineSMTPStage,
    envelope: MailEngineEnvelope,
    rawMessage: Data
  ) async throws -> MailEngineSMTPOutcome {
    try await handlePreContentCancellation(stage, envelope: envelope)
    await state.record(.submitted(connectionID: connectionID))
    await state.record(
      .submissionReceived(
        connectionID: connectionID,
        envelope: envelope,
        rawMessage: rawMessage
      )
    )
    if case .cancelledAfterMessageContent = stage {
      await state.record(
        .submissionContentAccepted(connectionID: connectionID, rawMessage: rawMessage)
      )
      return await waitForPostContentTermination()
    }
    if transmitsMessageContent(stage) {
      await state.record(
        .submissionContentAccepted(connectionID: connectionID, rawMessage: rawMessage)
      )
    }
    await invalidateSMTPChannelIfNeeded(after: stage)
    return classifySMTPStage(stage)
  }

  private func invalidateSMTPChannelIfNeeded(after stage: MailEngineSMTPStage) async {
    switch stage {
    case .authenticationRejectedBeforeSubmission, .transportUnavailableAfterSenderAccepted,
      .transportUnavailableBeforeSubmission, .connectionLostAfterSubmission:
      smtpRequiresReauthentication = true
      await state.record(.serviceClosed(connectionID: connectionID, service: .smtp))
    case .accepted, .cancelledAfterMessageContent, .cancelledAfterSenderAccepted,
      .cancelledBeforeSubmission, .dataRejectedBeforeSubmission, .finalResponse,
      .recipientRejectedAfterAccepted, .recipientRejectedBeforeSubmission,
      .senderRejectedBeforeSubmission:
      break
    }
  }

  private func handlePreContentCancellation(
    _ stage: MailEngineSMTPStage,
    envelope: MailEngineEnvelope
  ) async throws {
    if case .cancelledBeforeSubmission = stage {
      await state.record(.submissionStarted(connectionID: connectionID))
      try await waitForPreContentCancellation()
    }
    if case .cancelledAfterSenderAccepted = stage {
      await state.record(.submitted(connectionID: connectionID))
      await state.record(
        .submissionEnvelopeAccepted(connectionID: connectionID, envelope: envelope)
      )
      try await waitForPreContentCancellation()
    }
  }

  private func waitForPreContentCancellation() async throws -> Never {
    do {
      while true {
        try Task.checkCancellation()
        try await Task.sleep(for: .milliseconds(10))
      }
    } catch is CancellationError {
      smtpRequiresReauthentication = true
      await state.record(.submissionTransportTerminated(connectionID: connectionID))
      throw MailEngineError.cancelled
    }
  }

  private func waitForPostContentTermination() async -> MailEngineSMTPOutcome {
    do {
      while true {
        if isClosed {
          return .ambiguous
        }
        try Task.checkCancellation()
        try await Task.sleep(for: .milliseconds(10))
      }
    } catch {
      smtpRequiresReauthentication = true
      await state.record(.submissionTransportTerminated(connectionID: connectionID))
      return .ambiguous
    }
  }

  private func transmitsMessageContent(_ stage: MailEngineSMTPStage) -> Bool {
    switch stage {
    case .accepted, .connectionLostAfterSubmission, .finalResponse:
      true
    case .authenticationRejectedBeforeSubmission, .cancelledAfterMessageContent,
      .cancelledAfterSenderAccepted, .cancelledBeforeSubmission, .dataRejectedBeforeSubmission,
      .recipientRejectedAfterAccepted, .recipientRejectedBeforeSubmission,
      .senderRejectedBeforeSubmission, .transportUnavailableAfterSenderAccepted,
      .transportUnavailableBeforeSubmission:
      false
    }
  }

  private func classifySMTPStage(_ stage: MailEngineSMTPStage) -> MailEngineSMTPOutcome {
    switch stage {
    case .accepted(let serverMessageID):
      .accepted(serverMessageID: serverMessageID)
    case .authenticationRejectedBeforeSubmission:
      .notSubmitted(.authentication)
    case .cancelledAfterMessageContent, .connectionLostAfterSubmission:
      .ambiguous
    case .cancelledAfterSenderAccepted, .cancelledBeforeSubmission:
      preconditionFailure("Cancellation is reported as MailEngineError.cancelled.")
    case .dataRejectedBeforeSubmission(let code):
      .notSubmitted(.dataRejected(code: code))
    case .finalResponse(let code) where code >= 500:
      .permanentlyRejected(code: code)
    case .finalResponse(let code):
      .transientlyRejected(code: code)
    case .recipientRejectedAfterAccepted(let code),
      .recipientRejectedBeforeSubmission(let code):
      .notSubmitted(.recipientRejected(code: code))
    case .senderRejectedBeforeSubmission(let code):
      .notSubmitted(.senderRejected(code: code))
    case .transportUnavailableAfterSenderAccepted, .transportUnavailableBeforeSubmission:
      .notSubmitted(.transportUnavailable)
    }
  }

  private func ensureOpen() async throws {
    guard !isClosed else {
      await state.recordClosedOperationRejection(connectionID: connectionID)
      throw MailEngineError.connectionClosed
    }
  }

  private func waitForIdleCancellation() async throws {
    do {
      while true {
        try await ensureOpen()
        try Task.checkCancellation()
        try await Task.sleep(for: .milliseconds(10))
      }
    } catch is CancellationError {
      await state.record(.idleCancelled(connectionID: connectionID))
      await state.record(.idleLateCallbackAttempted(connectionID: connectionID))
      throw MailEngineError.cancelled
    }
  }

  private func metadataUIDs() -> [Int64] {
    switch authorization {
    case .password(let username, _) where username == "first@example.com":
      [19, 18, 17]
    case .xoauth2(let username, _) where username == "second@example.com":
      [29, 28, 27]
    default:
      [9, 8, 7]
    }
  }

  private func metadataFlags(for uid: Int64) -> Set<String> {
    switch uid {
    case 9, 19, 29:
      ["\\Seen"]
    case 8, 18, 28:
      ["\\Flagged"]
    default:
      ["\\Answered"]
    }
  }

  private func uidValidity(for mailbox: MailEngineMailboxIdentity) -> Int64 {
    uidValidityByMailbox[mailbox] ?? 44
  }
}

private final class RecordingMailEngineProductionLogSink:
  MailEngineProductionLogSinking,
  @unchecked Sendable
{
  private let storage = LockedBox<[MailEngineDiagnosticEvent]>([])

  var events: [MailEngineDiagnosticEvent] { storage.value }

  func record(_ event: MailEngineDiagnosticEvent) {
    storage.withValue { $0.append(event) }
  }
}

private final class LockedBox<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValue: Value

  init(_ value: Value) {
    storedValue = value
  }

  var value: Value {
    lock.withLock { storedValue }
  }

  func withValue(_ operation: (inout Value) -> Void) {
    lock.withLock { operation(&storedValue) }
  }
}
