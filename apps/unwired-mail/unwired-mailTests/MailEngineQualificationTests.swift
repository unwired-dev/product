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
  func waitForIdleStarts(_ count: Int, timeout: Duration) async throws
}

enum MailEngineQualificationFixture: Sendable {
  case bodyFetchUntilCancelled
  case connectionFailure(service: MailEngineService, error: MailEngineError)
  case copyOutcomeUnknown
  case idleDisconnectThenRecover
  case idleUntilCancelled
  case malformedCopyUIDMapping
  case mismatchedUIDMappingCardinality
  case malformedMoveUIDMapping
  case maximumTLS(service: MailEngineService, version: MailEngineTLSVersion)
  case moveOutcomeUnknown
  case reducedCapabilityMove(hasMove: Bool)
  case sentAppendOutcomeUnknown
  case sentAppendFailsOnce
  case sentAppendPermanentlyRejected
  case smtpStages([MailEngineSMTPStage])
  case successful
  case uidValidityReset
  case xoauth2Challenge(service: MailEngineService)
}

enum MailEngineSMTPStage: Sendable {
  case accepted(serverMessageID: String?)
  case authenticationRejectedBeforeSubmission
  case cancelledAfterMessageContent
  case cancelledBeforeSubmission
  case connectionLostAfterSubmission
  case dataRejectedBeforeSubmission(code: Int)
  case finalResponse(code: Int)
  case recipientRejectedBeforeSubmission(code: Int)
  case transportUnavailableBeforeSubmission
}

enum MailEngineQualificationEvent: Equatable, Sendable {
  case authenticationChallengeAnswered(connectionID: String, service: MailEngineService)
  case authenticationStarted(connectionID: String, service: MailEngineService)
  case authenticated(connectionID: String, service: MailEngineService)
  case bodyFetchCancelled(connectionID: String)
  case bodyFetchStarted(connectionID: String)
  case closed(connectionID: String)
  case idleCancelled(connectionID: String)
  case idleEventDelivered(connectionID: String, event: MailEngineIdleEvent)
  case idleStarted(connectionID: String)
  case movePreservedUnrelatedDeletedUIDs(connectionID: String, uids: [Int64])
  case serviceClosed(connectionID: String, service: MailEngineService)
  case sentAppend(connectionID: String)
  case sentAppendReceived(
    connectionID: String,
    mailbox: MailEngineMailboxIdentity,
    rawMessage: Data
  )
  case submitted(connectionID: String)
  case submissionReceived(
    connectionID: String,
    envelope: MailEngineEnvelope,
    rawMessage: Data
  )
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
    case .bodyFetchCancelled, .bodyFetchStarted, .closed, .idleCancelled, .idleEventDelivered,
      .idleStarted,
      .movePreservedUnrelatedDeletedUIDs, .sentAppend, .sentAppendReceived, .submitted,
      .submissionReceived:
      false
    }
  }
}

struct MailEngineQualificationContract {
  let factory: any MailEngineQualificationCandidateFactory

  func verifySetupTransportAuthenticationAndCapabilities() async throws {
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
    try await verifyXOAUTH2Challenge(service: .imap, connectionID: "xoauth2-imap-challenge")
    try await verifyXOAUTH2Challenge(service: .smtp, connectionID: "xoauth2-smtp-challenge")
    verifySuccessfulSnapshot(implicitConnection.snapshot)
    XCTAssertEqual(
      startTLSConnection.snapshot.transportSecurity,
      [.imap: .tls13, .smtp: .tls13]
    )
    XCTAssertEqual(
      mixedModeConnection.snapshot.transportSecurity,
      [.imap: .tls13, .smtp: .tls13]
    )
    await verifySetupEvents()
  }

  private func verifyXOAUTH2Challenge(
    service: MailEngineService,
    connectionID: String
  ) async throws {
    _ = try await connect(
      fixture: .xoauth2Challenge(service: service),
      authorization: .xoauth2(
        username: "oauth-challenge@example.com",
        accessToken: "oauth-challenge-token"
      ),
      connectionID: connectionID
    )
  }

  private func verifySuccessfulSnapshot(_ snapshot: MailEngineConnectionSnapshot) {
    XCTAssertEqual(
      snapshot.transportSecurity,
      [.imap: .tls13, .smtp: .tls13]
    )
    XCTAssertEqual(
      snapshot.capabilities,
      [.idle, .move, .specialUse, .uidPlus]
    )
    XCTAssertEqual(
      snapshot.mailboxes,
      [
        MailEngineMailbox(identity: MailEngineMailboxIdentity("INBOX"), specialUses: []),
        MailEngineMailbox(
          identity: MailEngineMailboxIdentity("Sent"),
          specialUses: [.sent]
        ),
      ]
    )
  }

  private func verifySetupEvents() async {
    let events = await factory.events()
    for connectionID in ["implicit-success", "starttls-success", "mixed-mode-success"] {
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
    var expected: [MailEngineQualificationEvent] = [
      .tlsEstablished(connectionID: connectionID, service: service, version: .tls13),
      .authenticationStarted(connectionID: connectionID, service: service),
    ]
    if includesChallenge {
      expected.append(
        .authenticationChallengeAnswered(connectionID: connectionID, service: service)
      )
    }
    expected.append(.authenticated(connectionID: connectionID, service: service))
    XCTAssertEqual(events.filter { $0.belongs(to: connectionID, service: service) }, expected)
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
        XCTAssertEqual(tls12Connection.snapshot.transportSecurity[service], .tls12)
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
      sourceUIDs: [5, 4],
      sourceUIDValidity: 44,
      from: inbox,
      to: archive
    )
    let move = try await session.move(
      sourceUIDs: [9, 8],
      sourceUIDValidity: 44,
      from: inbox,
      to: archive
    )

    XCTAssertEqual(copy.sourceMailbox, inbox)
    XCTAssertEqual(copy.sourceUIDValidity, 44)
    XCTAssertEqual(copy.destinationMailbox, archive)
    XCTAssertEqual(copy.destinationUIDValidity, 91)
    XCTAssertEqual(
      copy.pairs,
      [
        MailEngineUIDPair(destinationUID: 105, sourceUID: 5),
        MailEngineUIDPair(destinationUID: 104, sourceUID: 4),
      ]
    )
    XCTAssertEqual(move.sourceMailbox, inbox)
    XCTAssertEqual(move.sourceUIDValidity, 44)
    XCTAssertEqual(move.destinationMailbox, archive)
    XCTAssertEqual(move.destinationUIDValidity, 92)
    XCTAssertEqual(
      move.pairs,
      [
        MailEngineUIDPair(destinationUID: 209, sourceUID: 9),
        MailEngineUIDPair(destinationUID: 208, sourceUID: 8),
      ]
    )
    try await verifyInvalidUIDMappings(inbox: inbox, archive: archive)
    try await verifyPermanentIMAPRejection()
    try await verifyReducedCapabilityMoveSafety(inbox: inbox, archive: archive)
    try await verifyUnknownMutationOutcome(inbox: inbox, archive: archive)
    try await verifyUIDValidityReset(inbox: inbox, archive: archive)
  }

  private func verifyUnknownMutationOutcome(
    inbox: MailEngineMailboxIdentity,
    archive: MailEngineMailboxIdentity
  ) async throws {
    let copySession = try await connect(fixture: .copyOutcomeUnknown).session
    do {
      _ = try await copySession.copy(
        sourceUIDs: [5],
        sourceUIDValidity: 44,
        from: inbox,
        to: archive
      )
      XCTFail("An indeterminate copy outcome must be classified for reconciliation.")
    } catch {
      XCTAssertEqual(error as? MailEngineError, .operationOutcomeUnknown)
    }
    let moveSession = try await connect(fixture: .moveOutcomeUnknown).session
    do {
      _ = try await moveSession.move(
        sourceUIDs: [5],
        sourceUIDValidity: 44,
        from: inbox,
        to: archive
      )
      XCTFail("An indeterminate move outcome must be classified for reconciliation.")
    } catch {
      XCTAssertEqual(error as? MailEngineError, .operationOutcomeUnknown)
    }
    let appendSession = try await connect(fixture: .sentAppendOutcomeUnknown).session
    do {
      _ = try await appendSession.appendToSent(
        Data("indeterminate append".utf8),
        mailbox: MailEngineMailboxIdentity("Sent")
      )
      XCTFail("An indeterminate Sent append must be classified for reconciliation.")
    } catch {
      XCTAssertEqual(error as? MailEngineError, .operationOutcomeUnknown)
    }
  }

  private func verifyUIDValidityReset(
    inbox: MailEngineMailboxIdentity,
    archive: MailEngineMailboxIdentity
  ) async throws {
    let session = try await connect(fixture: .uidValidityReset).session
    let archivePageBeforeReset = try await session.loadMetadataPage(
      mailbox: archive,
      beforeUID: nil,
      limit: 1
    )
    let pageBeforeReset = try await session.loadMetadataPage(
      mailbox: inbox,
      beforeUID: nil,
      limit: 1
    )
    let events = LockedBox<[MailEngineIdleEvent]>([])

    let resetTask = Task {
      try await session.idle(mailbox: inbox) { event in
        events.withValue { $0.append(event) }
      }
    }
    try await waitForIdleEvents(events, count: 1, timeout: .seconds(2))
    XCTAssertEqual(events.value, [.mailboxReset(uidValidity: 99)])
    await assertIdleCancellation(
      resetTask,
      failureMessage: "UIDVALIDITY-reset IDLE must remain active until cancelled."
    )
    XCTAssertEqual(archivePageBeforeReset.uidValidity, 73)
    do {
      _ = try await session.fetchBodyParts(
        [MailEngineBodyPartSelector("1.TEXT")],
        for: pageBeforeReset.messages[0].identity
      )
      XCTFail("A message identity from the prior UIDVALIDITY must be rejected.")
    } catch {
      XCTAssertEqual(error as? MailEngineError, .staleMessageIdentity)
    }
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
    try await verifyUnaffectedArchive(
      session: session,
      pageBeforeReset: archivePageBeforeReset,
      inbox: inbox
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
      sourceUIDs: [pageBeforeReset.messages[0].identity.uid],
      sourceUIDValidity: pageBeforeReset.uidValidity,
      from: pageBeforeReset.messages[0].identity.mailbox,
      to: inbox
    )
  }

  private func verifyStaleMutationInputs(
    session: any MailEngineSession,
    message: MailEngineMessageIdentity,
    archive: MailEngineMailboxIdentity
  ) async {
    do {
      _ = try await session.copy(
        sourceUIDs: [message.uid],
        sourceUIDValidity: message.uidValidity,
        from: message.mailbox,
        to: archive
      )
      XCTFail("A stale copy input must be rejected.")
    } catch {
      XCTAssertEqual(error as? MailEngineError, .staleMessageIdentity)
    }
    do {
      _ = try await session.move(
        sourceUIDs: [message.uid],
        sourceUIDValidity: message.uidValidity,
        from: message.mailbox,
        to: archive
      )
      XCTFail("A stale move input must be rejected.")
    } catch {
      XCTAssertEqual(error as? MailEngineError, .staleMessageIdentity)
    }
  }

  private func verifyInvalidUIDMappings(
    inbox: MailEngineMailboxIdentity,
    archive: MailEngineMailboxIdentity
  ) async throws {
    let malformedCopySession = try await connect(fixture: .malformedCopyUIDMapping).session
    do {
      _ = try await malformedCopySession.copy(
        sourceUIDs: [4, 5],
        sourceUIDValidity: 44,
        from: inbox,
        to: archive
      )
      XCTFail("The candidate must reject a COPYUID response missing a requested UID.")
    } catch {
      XCTAssertEqual(error as? MailEngineUIDMappingError, .mismatchedSourceUIDs)
    }
    let malformedMoveSession = try await connect(fixture: .malformedMoveUIDMapping).session
    do {
      _ = try await malformedMoveSession.move(
        sourceUIDs: [4, 5],
        sourceUIDValidity: 44,
        from: inbox,
        to: archive
      )
      XCTFail("The candidate must reject a MOVEUID response with repeated destination UIDs.")
    } catch {
      XCTAssertEqual(error as? MailEngineUIDMappingError, .repeatedUID)
    }
    let mismatchedCardinalitySession = try await connect(
      fixture: .mismatchedUIDMappingCardinality
    ).session
    do {
      _ = try await mismatchedCardinalitySession.copy(
        sourceUIDs: [4, 5],
        sourceUIDValidity: 44,
        from: inbox,
        to: archive
      )
      XCTFail("The candidate must reject unequal source and destination UID counts.")
    } catch {
      XCTAssertEqual(error as? MailEngineUIDMappingError, .mismatchedCardinality)
    }
  }

  private func verifyPermanentIMAPRejection() async throws {
    let session = try await connect(fixture: .sentAppendPermanentlyRejected).session
    do {
      _ = try await session.appendToSent(
        Data("permanently rejected".utf8),
        mailbox: MailEngineMailboxIdentity("Sent")
      )
      XCTFail("A permanent tagged IMAP rejection must preserve its classification.")
    } catch {
      XCTAssertEqual(
        error as? MailEngineError,
        .protocolRejected(code: "NOPERM", retryable: false)
      )
    }
  }

  private func verifyReducedCapabilityMoveSafety(
    inbox: MailEngineMailboxIdentity,
    archive: MailEngineMailboxIdentity
  ) async throws {
    for hasMove in [false, true] {
      let connectionID = hasMove ? "move-without-uidplus" : "copy-delete-without-uidplus"
      let connection = try await connect(
        fixture: .reducedCapabilityMove(hasMove: hasMove),
        connectionID: connectionID
      )
      XCTAssertEqual(connection.snapshot.capabilities.contains(.move), hasMove)
      XCTAssertFalse(connection.snapshot.capabilities.contains(.uidPlus))
      _ = try await connection.session.move(
        sourceUIDs: [9],
        sourceUIDValidity: 44,
        from: inbox,
        to: archive
      )
      let events = await factory.events()
      XCTAssertTrue(
        events.contains(
          .movePreservedUnrelatedDeletedUIDs(connectionID: connectionID, uids: [6])
        ),
        "Reduced-capability removal must not expunge unrelated deleted messages."
      )
    }
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

    let requestedParts: Set<MailEngineBodyPartSelector> = [
      MailEngineBodyPartSelector("1.TEXT"),
      MailEngineBodyPartSelector("2.MIME"),
    ]
    let parts = try await session.fetchBodyParts(
      requestedParts,
      for: firstPage.messages[0].identity
    )
    XCTAssertEqual(Set(parts.map(\.selector)), requestedParts)
    XCTAssertEqual(parts.count, requestedParts.count)
    XCTAssertEqual(
      parts,
      [
        MailEngineBodyPart(data: Data("INBOX-44-9-1.TEXT".utf8), selector: .init("1.TEXT")),
        MailEngineBodyPart(data: Data("INBOX-44-9-2.MIME".utf8), selector: .init("2.MIME")),
      ]
    )
    let secondMessageParts = try await session.fetchBodyParts(
      requestedParts,
      for: firstPage.messages[1].identity
    )
    XCTAssertEqual(
      secondMessageParts.map(\.data),
      [
        Data("INBOX-44-8-1.TEXT".utf8),
        Data("INBOX-44-8-2.MIME".utf8),
      ]
    )
  }

  private func assertMetadataPagination(
    firstPage: MailEngineMetadataPage,
    historicalPage: MailEngineMetadataPage
  ) {
    XCTAssertEqual(firstPage.uidValidity, 44)
    XCTAssertEqual(firstPage.nextOlderUID, 8)
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
        identity: MailEngineMessageIdentity(
          mailbox: mailbox,
          uid: uid,
          uidValidity: uidValidity
        ),
        internalDate: Date(timeIntervalSince1970: TimeInterval(uid)),
        rfcMessageID: "<\(uid)@example.com>"
      )
    }
  }

  func verifyIDLEAndConnectionIsolation() async throws {
    try await verifyIDLERecovery()
    try await verifyOverlappingConnectionIsolation()
  }

  private func verifyIDLERecovery() async throws {
    let recoveringSession = try await connect(fixture: .idleDisconnectThenRecover).session
    let inbox = MailEngineMailboxIdentity("INBOX")
    do {
      try await recoveringSession.idle(mailbox: inbox) { _ in }
      XCTFail("The first IDLE attempt should disconnect.")
    } catch {
      XCTAssertEqual(error as? MailEngineError, .connectionClosed)
    }
    let recoveredEvents = LockedBox<[MailEngineIdleEvent]>([])
    let recoveryTask = Task {
      try await recoveringSession.idle(mailbox: inbox) { event in
        recoveredEvents.withValue { $0.append(event) }
      }
    }
    try await waitForIdleEvents(recoveredEvents, count: 1, timeout: .seconds(2))
    XCTAssertEqual(recoveredEvents.value, [.changedUIDs([10])])
    await assertIdleCancellation(
      recoveryTask,
      failureMessage: "Recovered IDLE must remain active until cancelled."
    )
  }

  private func verifyOverlappingConnectionIsolation() async throws {
    let inbox = MailEngineMailboxIdentity("INBOX")
    let first = try await connect(
      fixture: .idleUntilCancelled,
      authorization: .password(username: "first@example.com", password: "first-password"),
      connectionID: "connection-one"
    ).session
    let second = try await connect(
      fixture: .idleUntilCancelled,
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
      try await second.idle(mailbox: inbox) { event in
        secondCallbacks.withValue { $0.append(event) }
      }
    }
    try await factory.waitForIdleStarts(4, timeout: .seconds(2))
    try await waitForIdleEvents(firstCallbacks, count: 1, timeout: .seconds(2))
    try await waitForIdleEvents(secondCallbacks, count: 1, timeout: .seconds(2))
    XCTAssertEqual(firstCallbacks.value, [.changedUIDs([19])])
    XCTAssertEqual(secondCallbacks.value, [.changedUIDs([29])])

    await assertIdleCancellation(
      firstTask, failureMessage: "Cancelling IDLE must report cancellation.")
    let cancellations = await idleCancellationEvents()
    XCTAssertTrue(cancellations.contains(.idleCancelled(connectionID: "connection-one")))
    XCTAssertFalse(cancellations.contains(.idleCancelled(connectionID: "connection-two")))
    let firstPage = try await first.loadMetadataPage(
      mailbox: inbox,
      beforeUID: nil,
      limit: 1
    )
    let secondPage = try await second.loadMetadataPage(
      mailbox: inbox,
      beforeUID: nil,
      limit: 1
    )
    XCTAssertEqual(firstPage.messages.map(\.identity.uid), [19])
    XCTAssertEqual(secondPage.messages.map(\.identity.uid), [29])

    await assertIdleCancellation(
      secondTask,
      failureMessage: "Cancelling the second IDLE must report cancellation."
    )
    try await verifyNonIdleCancellationIsolation(inbox: inbox)
  }

  private func verifyNonIdleCancellationIsolation(
    inbox: MailEngineMailboxIdentity
  ) async throws {
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
    let fetchTask = Task {
      try await first.fetchBodyParts(
        [MailEngineBodyPartSelector("1.TEXT")],
        for: MailEngineMessageIdentity(mailbox: inbox, uid: 19, uidValidity: 44)
      )
    }
    try await factory.waitForBodyFetchStarts(1, timeout: .seconds(2))
    fetchTask.cancel()
    do {
      _ = try await fetchTask.value
      XCTFail("Cancelling the first body fetch must report cancellation.")
    } catch {
      XCTAssertEqual(error as? MailEngineError, .cancelled)
    }
    let secondPage = try await second.loadMetadataPage(
      mailbox: inbox,
      beforeUID: nil,
      limit: 1
    )
    XCTAssertEqual(secondPage.messages.map(\.identity.uid), [29])
    let events = await factory.events()
    XCTAssertTrue(events.contains(.bodyFetchCancelled(connectionID: "body-fetch-one")))
    XCTAssertFalse(events.contains(.bodyFetchCancelled(connectionID: "body-fetch-two")))
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
    var observed: [MailEngineSMTPOutcome] = []
    let envelope = MailEngineEnvelope(
      recipients: ["recipient@example.com"],
      sender: "sender@example.com"
    )
    let rawMessage = Data("Subject: Contract\r\n\r\nBody".utf8)
    for _ in stages {
      observed.append(
        try await session.submit(
          envelope: envelope,
          rawMessage: rawMessage
        )
      )
    }
    XCTAssertEqual(observed, expectedOutcomes)
    try await verifySMTPCancellation()
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

  private func smtpStagesAndExpectedOutcomes() -> (
    stages: [MailEngineSMTPStage],
    outcomes: [MailEngineSMTPOutcome]
  ) {
    (
      [
        .transportUnavailableBeforeSubmission,
        .authenticationRejectedBeforeSubmission,
        .recipientRejectedBeforeSubmission(code: 451),
        .recipientRejectedBeforeSubmission(code: 550),
        .dataRejectedBeforeSubmission(code: 451),
        .dataRejectedBeforeSubmission(code: 550),
        .finalResponse(code: 451),
        .finalResponse(code: 550),
        .cancelledAfterMessageContent,
        .connectionLostAfterSubmission,
        .accepted(serverMessageID: "smtp-message-1"),
      ],
      [
        .notSubmitted(.transportUnavailable),
        .notSubmitted(.authentication),
        .notSubmitted(.recipientRejected(code: 451)),
        .notSubmitted(.recipientRejected(code: 550)),
        .notSubmitted(.dataRejected(code: 451)),
        .notSubmitted(.dataRejected(code: 550)),
        .transientlyRejected(code: 451),
        .permanentlyRejected(code: 550),
        .ambiguous,
        .ambiguous,
        .accepted(serverMessageID: "smtp-message-1"),
      ]
    )
  }

  private func verifySMTPCancellation() async throws {
    let cancelledSession = try await connect(
      fixture: .smtpStages([.cancelledBeforeSubmission])
    ).session
    do {
      _ = try await cancelledSession.submit(
        envelope: MailEngineEnvelope(
          recipients: ["recipient@example.com"],
          sender: "sender@example.com"
        ),
        rawMessage: Data("Subject: Cancelled\r\n\r\nBody".utf8)
      )
      XCTFail("Cancellation before SMTP submission should be reported.")
    } catch {
      XCTAssertEqual(error as? MailEngineError, .cancelled)
    }
  }

  private func verifySentAppendRecovery() async throws {
    let sentRecoverySession = try await connect(fixture: .sentAppendFailsOnce).session
    let rawMessage = Data("message".utf8)
    let accepted = try await sentRecoverySession.submit(
      envelope: MailEngineEnvelope(
        recipients: ["recipient@example.com"],
        sender: "sender@example.com"
      ),
      rawMessage: Data("Subject: Sent recovery\r\n\r\nBody".utf8)
    )
    XCTAssertEqual(accepted, .accepted(serverMessageID: "smtp-message-1"))
    do {
      _ = try await sentRecoverySession.appendToSent(
        rawMessage,
        mailbox: MailEngineMailboxIdentity("Sent")
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
      mailbox: MailEngineMailboxIdentity("Sent")
    )
    XCTAssertEqual(appended.uidValidity, 45)
    XCTAssertEqual(appended.uid, 11)
    let events = await factory.events()
    XCTAssertEqual(
      events.filter {
        $0
          == .sentAppendReceived(
            connectionID: "connection-a",
            mailbox: MailEngineMailboxIdentity("Sent"),
            rawMessage: rawMessage
          )
      }.count,
      2
    )
  }

  func verifyProtocolTracePrivacy() async throws {
    let sink = RecordingMailEngineProductionLogSink()
    let logger = PrivacyPreservingMailEngineLogger(sink: sink)

    _ = try await factory.makeEngine(fixture: .successful).connect(
      configuration: configuration(
        fixture: .successful,
        authorization: .xoauth2(
          username: "private-mailbox@example.com",
          accessToken: "private-bearer-token"
        )
      ),
      logger: logger
    )
    _ = try await factory.makeEngine(fixture: .successful).connect(
      configuration: configuration(
        fixture: .successful,
        authorization: .password(
          username: "private-password-mailbox@example.com",
          password: "private-password"
        )
      ),
      logger: logger
    )

    XCTAssertEqual(sink.events, [.connected, .connected])
    let candidateOutput = await factory.capturedCandidateLogOutput()
    let secrets = [
      "private-mailbox@example.com",
      "private-bearer-token",
      "private-password-mailbox@example.com",
      "private-password",
      "private-mailbox",
      "private message",
    ]
    let encodedAuthenticationExchanges = [
      Data(
        "user=private-mailbox@example.com\u{1}auth=Bearer private-bearer-token\u{1}\u{1}".utf8
      ).base64EncodedData(),
      Data("\0private-password-mailbox@example.com\0private-password".utf8)
        .base64EncodedData(),
    ]
    for secret in secrets.map({ Data($0.utf8) }) + encodedAuthenticationExchanges {
      XCTAssertFalse(
        candidateOutput.range(of: secret) != nil,
        "Candidate-owned logging leaked a qualification secret."
      )
    }
  }

  func verifyConnectionLifecycle() async throws {
    let session = try await connect(fixture: .successful).session
    await session.close()
    let inbox = MailEngineMailboxIdentity("INBOX")
    let archive = MailEngineMailboxIdentity("Archive")
    let message = MailEngineMessageIdentity(mailbox: inbox, uid: 9, uidValidity: 44)
    await assertClosedOperation("appendToSent") {
      _ = try await session.appendToSent(Data("message".utf8), mailbox: archive)
    }
    await assertClosedOperation("copy") {
      _ = try await session.copy(
        sourceUIDs: [9],
        sourceUIDValidity: 44,
        from: inbox,
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
        sourceUIDs: [9],
        sourceUIDValidity: 44,
        from: inbox,
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
    let events = await factory.events()
    XCTAssertTrue(events.contains(.closed(connectionID: "connection-a")))
  }

  private func assertClosedOperation(
    _ operationName: String,
    operation: () async throws -> Void
  ) async {
    do {
      try await operation()
      XCTFail("A closed session should reject \(operationName).")
    } catch {
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
        smtpTransportMode: smtpTransportMode
      ),
      logger: PrivacyPreservingMailEngineLogger(sink: RecordingMailEngineProductionLogSink())
    )
  }

  private func assertConnectionFails(
    fixture: MailEngineQualificationFixture,
    authorization: MailEngineAuthorization = .password(
      username: "private-mailbox@example.com",
      password: "private-password"
    ),
    failedService: MailEngineService,
    imapTransportMode: MailEngineTransportMode = .implicitTLS,
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
          smtpTransportMode: smtpTransportMode
        ),
        logger: PrivacyPreservingMailEngineLogger(sink: RecordingMailEngineProductionLogSink())
      )
      XCTFail("The candidate should reject this connection.")
    } catch {
      XCTAssertEqual(error as? MailEngineError, expectedError)
    }
    let events = await factory.events()
    let serviceEvents = events.filter { $0.belongs(to: connectionID, service: failedService) }
    if expectedError == .authenticationRejected {
      XCTAssertEqual(
        serviceEvents,
        [
          .tlsEstablished(connectionID: connectionID, service: failedService, version: .tls13),
          .authenticationStarted(connectionID: connectionID, service: failedService),
        ]
      )
    } else {
      XCTAssertEqual(
        serviceEvents,
        [],
        "Authentication must not start on a service whose secure setup failed."
      )
    }
    if failedService == .smtp {
      XCTAssertTrue(
        events.contains(.serviceClosed(connectionID: connectionID, service: .imap)),
        "A candidate must close IMAP when later SMTP setup fails."
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
    smtpTransportMode: MailEngineTransportMode = .implicitTLS
  ) -> MailEngineConfiguration {
    factory.configuration(
      fixture: fixture,
      authorization: authorization,
      connectionID: connectionID,
      imapTransportMode: imapTransportMode,
      smtpTransportMode: smtpTransportMode
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

  func waitForIdleStarts(_ count: Int, timeout: Duration) async throws {
    try await state.waitForIdleStarts(count, timeout: timeout)
  }
}

private actor ScriptedMailEngineState {
  private(set) var events: [MailEngineQualificationEvent] = []
  private(set) var candidateLogOutput = Data()

  func record(_ event: MailEngineQualificationEvent) {
    events.append(event)
  }

  func recordCandidateLogOutput(_ output: Data) {
    candidateLogOutput.append(output)
  }

  func waitForBodyFetchStarts(_ count: Int, timeout: Duration) async throws {
    try await waitForEvents(count, timeout: timeout) {
      if case .bodyFetchStarted = $0 { return true }
      return false
    }
  }

  func waitForIdleStarts(_ count: Int, timeout: Duration) async throws {
    try await waitForEvents(count, timeout: timeout) {
      if case .idleStarted = $0 { return true }
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
      throw error
    }

    logger.record(.connected)

    return (
      snapshot(transportSecurity: transportSecurity),
      ScriptedMailEngineSession(
        authorization: configuration.authorization,
        connectionID: configuration.connectionID,
        fixture: fixture,
        state: state
      )
    )
  }

  private func establish(
    service: MailEngineService,
    configuration: MailEngineConfiguration
  ) async throws -> MailEngineTLSVersion {
    try await rejectConfiguredFailure(service: service, configuration: configuration)

    let negotiatedVersion: MailEngineTLSVersion
    if case .maximumTLS(let maximumService, let maximumTLSVersion) = fixture,
      maximumService == service
    {
      guard maximumTLSVersion >= configuration.minimumTLSVersion else {
        throw MailEngineError.tlsVersionUnsupported
      }
      negotiatedVersion = maximumTLSVersion
    } else {
      negotiatedVersion = .tls13
    }

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

  private func rejectConfiguredFailure(
    service: MailEngineService,
    configuration: MailEngineConfiguration
  ) async throws {
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
    transportSecurity: [MailEngineService: MailEngineTLSVersion]
  ) -> MailEngineConnectionSnapshot {
    let capabilities: Set<MailEngineCapability>
    if case .reducedCapabilityMove(let hasMove) = fixture {
      capabilities = hasMove ? [.idle, .move, .specialUse] : [.idle, .specialUse]
    } else {
      capabilities = [.idle, .move, .specialUse, .uidPlus]
    }
    return MailEngineConnectionSnapshot(
      capabilities: capabilities,
      mailboxes: [
        MailEngineMailbox(identity: MailEngineMailboxIdentity("INBOX"), specialUses: []),
        MailEngineMailbox(
          identity: MailEngineMailboxIdentity("Sent"),
          specialUses: [.sent]
        ),
      ],
      transportSecurity: transportSecurity
    )
  }
}

private actor ScriptedMailEngineSession: MailEngineSession {
  let authorization: MailEngineAuthorization
  let connectionID: String
  let fixture: MailEngineQualificationFixture
  let state: ScriptedMailEngineState
  private var appendAttempt = 0
  private var uidValidityByMailbox: [MailEngineMailboxIdentity: Int64] = [
    MailEngineMailboxIdentity("INBOX"): 44,
    MailEngineMailboxIdentity("Archive"): 73,
  ]
  private var idleAttempt = 0
  private var isClosed = false
  private var smtpStageIndex = 0

  init(
    authorization: MailEngineAuthorization,
    connectionID: String,
    fixture: MailEngineQualificationFixture,
    state: ScriptedMailEngineState
  ) {
    self.authorization = authorization
    self.connectionID = connectionID
    self.fixture = fixture
    self.state = state
  }

  func appendToSent(
    _ rawMessage: Data,
    mailbox: MailEngineMailboxIdentity
  ) async throws -> MailEngineMessageIdentity {
    try ensureOpen()
    appendAttempt += 1
    await state.record(.sentAppend(connectionID: connectionID))
    await state.record(
      .sentAppendReceived(
        connectionID: connectionID,
        mailbox: mailbox,
        rawMessage: rawMessage
      )
    )
    if case .sentAppendOutcomeUnknown = fixture {
      throw MailEngineError.operationOutcomeUnknown
    }
    if case .sentAppendFailsOnce = fixture, appendAttempt == 1 {
      throw MailEngineError.protocolRejected(code: "TRYAGAIN", retryable: true)
    }
    if case .sentAppendPermanentlyRejected = fixture {
      throw MailEngineError.protocolRejected(code: "NOPERM", retryable: false)
    }
    return MailEngineMessageIdentity(mailbox: mailbox, uid: 11, uidValidity: 45)
  }

  func close() async {
    isClosed = true
    await state.record(.closed(connectionID: connectionID))
  }

  func copy(
    sourceUIDs: [Int64],
    sourceUIDValidity: Int64,
    from sourceMailbox: MailEngineMailboxIdentity,
    to destinationMailbox: MailEngineMailboxIdentity
  ) async throws -> MailEngineUIDMapping {
    try ensureOpen()
    guard sourceUIDValidity == uidValidity(for: sourceMailbox) else {
      throw MailEngineError.staleMessageIdentity
    }
    if case .copyOutcomeUnknown = fixture {
      throw MailEngineError.operationOutcomeUnknown
    }
    let reported: MailEngineReportedUIDMapping
    if case .malformedCopyUIDMapping = fixture {
      reported = MailEngineReportedUIDMapping(
        destinationUIDValidity: 91,
        destinationUIDs: [104],
        sourceUIDs: [4]
      )
    } else if case .mismatchedUIDMappingCardinality = fixture {
      reported = MailEngineReportedUIDMapping(
        destinationUIDValidity: 91,
        destinationUIDs: [104],
        sourceUIDs: sourceUIDs
      )
    } else {
      reported = MailEngineReportedUIDMapping(
        destinationUIDValidity: 91,
        destinationUIDs: sourceUIDs.map { $0 + 100 },
        sourceUIDs: sourceUIDs
      )
    }
    return try MailEngineUIDMapping.validated(
      sourceMailbox: sourceMailbox,
      sourceUIDValidity: sourceUIDValidity,
      destinationMailbox: destinationMailbox,
      requestedSourceUIDs: sourceUIDs,
      reported: reported
    )
  }

  func fetchBodyParts(
    _ selectors: Set<MailEngineBodyPartSelector>,
    for message: MailEngineMessageIdentity
  ) async throws -> [MailEngineBodyPart] {
    try ensureOpen()
    guard message.uidValidity == uidValidity(for: message.mailbox) else {
      throw MailEngineError.staleMessageIdentity
    }
    if case .bodyFetchUntilCancelled = fixture,
      case .password(let username, _) = authorization,
      username == "first@example.com"
    {
      await state.record(.bodyFetchStarted(connectionID: connectionID))
      do {
        while true {
          try Task.checkCancellation()
          try await Task.sleep(for: .milliseconds(10))
        }
      } catch is CancellationError {
        await state.record(.bodyFetchCancelled(connectionID: connectionID))
        throw MailEngineError.cancelled
      }
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

  func idle(
    mailbox: MailEngineMailboxIdentity,
    onEvent: @escaping @Sendable (MailEngineIdleEvent) async -> Void
  ) async throws {
    try ensureOpen()
    idleAttempt += 1
    await state.record(.idleStarted(connectionID: connectionID))
    if case .idleDisconnectThenRecover = fixture {
      guard idleAttempt > 1 else { throw MailEngineError.connectionClosed }
      let event = MailEngineIdleEvent.changedUIDs([10])
      await onEvent(event)
      await state.record(.idleEventDelivered(connectionID: connectionID, event: event))
      try await waitForIdleCancellation()
    }
    if case .idleUntilCancelled = fixture {
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

  func loadMetadataPage(
    mailbox: MailEngineMailboxIdentity,
    beforeUID: Int64?,
    limit: Int
  ) async throws -> MailEngineMetadataPage {
    try ensureOpen()
    let availableUIDs = metadataUIDs().filter { uid in
      beforeUID.map { uid < $0 } ?? true
    }
    let selectedUIDs = Array(availableUIDs.prefix(limit))
    let hasMore = availableUIDs.count > selectedUIDs.count
    return MailEngineMetadataPage(
      messages: selectedUIDs.map {
        MailEngineMessageMetadata(
          flags: metadataFlags(for: $0),
          identity: MailEngineMessageIdentity(
            mailbox: mailbox,
            uid: $0,
            uidValidity: uidValidity(for: mailbox)
          ),
          internalDate: Date(timeIntervalSince1970: TimeInterval($0)),
          rfcMessageID: "<\($0)@example.com>"
        )
      },
      nextOlderUID: hasMore ? selectedUIDs.last : nil,
      uidValidity: uidValidity(for: mailbox)
    )
  }

  func move(
    sourceUIDs: [Int64],
    sourceUIDValidity: Int64,
    from sourceMailbox: MailEngineMailboxIdentity,
    to destinationMailbox: MailEngineMailboxIdentity
  ) async throws -> MailEngineUIDMapping {
    try ensureOpen()
    guard sourceUIDValidity == uidValidity(for: sourceMailbox) else {
      throw MailEngineError.staleMessageIdentity
    }
    if case .reducedCapabilityMove = fixture {
      await state.record(
        .movePreservedUnrelatedDeletedUIDs(connectionID: connectionID, uids: [6])
      )
    }
    if case .moveOutcomeUnknown = fixture {
      throw MailEngineError.operationOutcomeUnknown
    }
    let reported: MailEngineReportedUIDMapping
    if case .malformedMoveUIDMapping = fixture {
      reported = MailEngineReportedUIDMapping(
        destinationUIDValidity: 92,
        destinationUIDs: [204, 204],
        sourceUIDs: sourceUIDs
      )
    } else {
      reported = MailEngineReportedUIDMapping(
        destinationUIDValidity: 92,
        destinationUIDs: sourceUIDs.map { $0 + 200 },
        sourceUIDs: sourceUIDs
      )
    }
    return try MailEngineUIDMapping.validated(
      sourceMailbox: sourceMailbox,
      sourceUIDValidity: sourceUIDValidity,
      destinationMailbox: destinationMailbox,
      requestedSourceUIDs: sourceUIDs,
      reported: reported
    )
  }

  func submit(
    envelope: MailEngineEnvelope,
    rawMessage: Data
  ) async throws -> MailEngineSMTPOutcome {
    try ensureOpen()
    if case .smtpStages(let stages) = fixture, smtpStageIndex < stages.count {
      defer { smtpStageIndex += 1 }
      let stage = stages[smtpStageIndex]
      if case .cancelledBeforeSubmission = stage {
        throw MailEngineError.cancelled
      }
      await state.record(.submitted(connectionID: connectionID))
      await state.record(
        .submissionReceived(
          connectionID: connectionID,
          envelope: envelope,
          rawMessage: rawMessage
        )
      )
      return classifySMTPStage(stage)
    }
    await state.record(.submitted(connectionID: connectionID))
    return .accepted(serverMessageID: "smtp-message-1")
  }

  private func classifySMTPStage(_ stage: MailEngineSMTPStage) -> MailEngineSMTPOutcome {
    switch stage {
    case .accepted(let serverMessageID):
      .accepted(serverMessageID: serverMessageID)
    case .authenticationRejectedBeforeSubmission:
      .notSubmitted(.authentication)
    case .cancelledAfterMessageContent:
      .ambiguous
    case .cancelledBeforeSubmission:
      preconditionFailure("Cancellation is reported as MailEngineError.cancelled.")
    case .connectionLostAfterSubmission:
      .ambiguous
    case .dataRejectedBeforeSubmission(let code):
      .notSubmitted(.dataRejected(code: code))
    case .finalResponse(let code) where code >= 500:
      .permanentlyRejected(code: code)
    case .finalResponse(let code):
      .transientlyRejected(code: code)
    case .recipientRejectedBeforeSubmission(let code):
      .notSubmitted(.recipientRejected(code: code))
    case .transportUnavailableBeforeSubmission:
      .notSubmitted(.transportUnavailable)
    }
  }

  private func ensureOpen() throws {
    guard !isClosed else { throw MailEngineError.connectionClosed }
  }

  private func waitForIdleCancellation() async throws {
    do {
      while true {
        try Task.checkCancellation()
        try await Task.sleep(for: .milliseconds(10))
      }
    } catch is CancellationError {
      await state.record(.idleCancelled(connectionID: connectionID))
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
