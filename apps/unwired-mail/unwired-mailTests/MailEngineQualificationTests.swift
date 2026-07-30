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
  func waitForSubmissionStarts(_ count: Int, timeout: Duration) async throws
  func waitForSubmissionContentStarts(
    _ count: Int,
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
  case idleDisconnectThenRecover(maximumReconnectTLSVersion: MailEngineTLSVersion?)
  case idleUntilCancelled
  case inFlightOperationsUntilClosed
  case malformedCopyUIDMapping
  case mismatchedUIDMappingCardinality
  case malformedMoveUIDMapping
  case maximumTLS(service: MailEngineService, version: MailEngineTLSVersion)
  case overlappingUIDMutations
  case moveOutcomeUnknown
  case movePermanentlyRejected
  case moveRetryablyRejected
  case invalidDestinationUIDMapping(uid: Int64)
  case invalidSourceUIDMapping(uid: Int64)
  case invalidUIDValidityMapping(uidValidity: Int64)
  case reducedCapabilityMove(hasMove: Bool, hasUIDPlus: Bool)
  case repeatedSourceUIDMapping
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
  case recipientRejectedAfterAccepted(code: Int)
  case recipientRejectedBeforeSubmission(code: Int)
  case senderRejectedBeforeSubmission(code: Int)
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
  case copyReceived(
    connectionID: String,
    sourceUIDs: [Int64],
    sourceUIDValidity: Int64,
    sourceMailbox: MailEngineMailboxIdentity,
    destinationMailbox: MailEngineMailboxIdentity
  )
  case idleCancelled(connectionID: String)
  case idleEventDelivered(connectionID: String, event: MailEngineIdleEvent)
  case idleStarted(connectionID: String, mailbox: MailEngineMailboxIdentity)
  case metadataPageRequested(
    connectionID: String,
    mailbox: MailEngineMailboxIdentity,
    beforeUID: Int64?,
    limit: Int
  )
  case movePreservedUnrelatedDeletedUIDs(connectionID: String, uids: [Int64])
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
  case submissionStarted(connectionID: String)
  case submissionContentAccepted(connectionID: String, rawMessage: Data)
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
    case .bodyFetchCancelled, .bodyFetchStarted, .bodyPartsRequested, .closed, .copyReceived,
      .idleCancelled, .idleEventDelivered, .idleStarted, .metadataPageRequested,
      .movePreservedUnrelatedDeletedUIDs, .moveReceived, .sentAppend, .sentAppendReceived,
      .submissionContentAccepted, .submissionReceived, .submissionStarted, .submitted:
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
    let xoauth2IMAPConnection = try await verifyXOAUTH2Challenge(
      service: .imap,
      connectionID: "xoauth2-imap-challenge"
    )
    let xoauth2SMTPConnection = try await verifyXOAUTH2Challenge(
      service: .smtp,
      connectionID: "xoauth2-smtp-challenge"
    )
    let successfulSessions: [any MailEngineSession] = [
      implicitConnection.session,
      startTLSConnection.session,
      mixedModeConnection.session,
      xoauth2IMAPConnection.session,
      xoauth2SMTPConnection.session,
    ]
    verifySuccessfulSnapshot(implicitConnection.snapshot)
    verifySuccessfulSnapshot(startTLSConnection.snapshot)
    verifySuccessfulSnapshot(mixedModeConnection.snapshot)
    verifySuccessfulSnapshot(xoauth2IMAPConnection.snapshot)
    verifySuccessfulSnapshot(xoauth2SMTPConnection.snapshot)
    await verifySetupEvents()
    withExtendedLifetime(successfulSessions) {}
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

  private func assertMinimumTLS(_ snapshot: MailEngineConnectionSnapshot) {
    XCTAssertEqual(Set(snapshot.transportSecurity.keys), [.imap, .smtp])
    for version in snapshot.transportSecurity.values {
      XCTAssertGreaterThanOrEqual(version, .tls12)
    }
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

    assertSuccessfulUIDMappings(copy: copy, move: move, inbox: inbox, archive: archive)
    await assertSuccessfulUIDCommands(inbox: inbox, archive: archive)
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
        sourceUIDs: [5],
        sourceUIDValidity: 44,
        from: inbox,
        to: archive
      )
      XCTFail("An indeterminate copy outcome must be classified for reconciliation.")
    } catch {
      XCTAssertEqual(error as? MailEngineError, .operationOutcomeUnknown)
    }
    let moveSession = try await connect(
      fixture: .moveOutcomeUnknown,
      connectionID: "move-outcome-unknown"
    ).session
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
    try await verifyUnknownAppendOutcome()
    await assertUnknownMutationEvents()
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
  }

  private func assertUnknownMutationEvents() async {
    let events = await factory.events()
    XCTAssertEqual(
      events.filter {
        if case .copyReceived(let connectionID, _, _, _, _) = $0 {
          return connectionID == "copy-outcome-unknown"
        }
        return false
      }.count,
      1,
      "An uncertain COPY outcome must not replay any mutation command."
    )
    XCTAssertEqual(
      events.filter {
        if case .moveReceived(let connectionID, _, _, _, _) = $0 {
          return connectionID == "move-outcome-unknown"
        }
        return false
      }.count,
      1,
      "An uncertain MOVE outcome must not replay any mutation command."
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
    try await verifyUnaffectedArchive(
      session: session,
      pageBeforeReset: archivePageBeforeReset,
      inbox: inbox
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

  private func verifyInvalidUIDMappings(
    inbox: MailEngineMailboxIdentity,
    archive: MailEngineMailboxIdentity
  ) async throws {
    let malformedCopySession = try await connect(fixture: .malformedCopyUIDMapping).session
    let malformedCopyEvent = copyEvent(inbox: inbox, archive: archive)
    let malformedCopyEvents = await mutationEvents(connectionID: "connection-a")
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
    await assertOnlyNewMutationEvent(malformedCopyEvent, after: malformedCopyEvents)
    let malformedMoveSession = try await connect(fixture: .malformedMoveUIDMapping).session
    let malformedMoveEvent = moveEvent(inbox: inbox, archive: archive)
    let malformedMoveEvents = await mutationEvents(connectionID: "connection-a")
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
    await assertOnlyNewMutationEvent(malformedMoveEvent, after: malformedMoveEvents)
    try await verifyRepeatedSourceUIDMapping(inbox: inbox, archive: archive)
    try await verifyMismatchedCardinalityMapping(inbox: inbox, archive: archive)
    try await verifyInvalidUIDValues(inbox: inbox, archive: archive)
  }

  private func verifyMismatchedCardinalityMapping(
    inbox: MailEngineMailboxIdentity,
    archive: MailEngineMailboxIdentity
  ) async throws {
    let mismatchedCardinalitySession = try await connect(
      fixture: .mismatchedUIDMappingCardinality
    ).session
    let copyEvent = copyEvent(inbox: inbox, archive: archive)
    let copyEventCount = await mutationEventCount(copyEvent)
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
    await assertExactlyOneNewMutationEvent(
      copyEvent,
      after: copyEventCount
    )
    let moveEvent = moveEvent(inbox: inbox, archive: archive)
    let moveEventCount = await mutationEventCount(moveEvent)
    do {
      _ = try await mismatchedCardinalitySession.move(
        sourceUIDs: [4, 5],
        sourceUIDValidity: 44,
        from: inbox,
        to: archive
      )
      XCTFail("The candidate must reject unequal MOVE source and destination UID counts.")
    } catch {
      XCTAssertEqual(error as? MailEngineUIDMappingError, .mismatchedCardinality)
    }
    await assertExactlyOneNewMutationEvent(
      moveEvent,
      after: moveEventCount
    )
  }

  private func verifyRepeatedSourceUIDMapping(
    inbox: MailEngineMailboxIdentity,
    archive: MailEngineMailboxIdentity
  ) async throws {
    let session = try await connect(fixture: .repeatedSourceUIDMapping).session
    let event = moveEvent(inbox: inbox, archive: archive)
    let eventCount = await mutationEventCount(event)
    do {
      _ = try await session.move(
        sourceUIDs: [4, 5],
        sourceUIDValidity: 44,
        from: inbox,
        to: archive
      )
      XCTFail("The candidate must reject a MOVEUID response with repeated source UIDs.")
    } catch {
      XCTAssertEqual(error as? MailEngineUIDMappingError, .repeatedUID)
    }
    await assertExactlyOneNewMutationEvent(event, after: eventCount)
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
        let eventCount = await mutationEventCount(event)
        do {
          _ = try await invalidUIDSession.copy(
            sourceUIDs: [4, 5],
            sourceUIDValidity: 44,
            from: inbox,
            to: archive
          )
          XCTFail("The candidate must reject UIDs outside the IMAP protocol range.")
        } catch {
          XCTAssertEqual(error as? MailEngineUIDMappingError, .invalidUID)
        }
        await assertExactlyOneNewMutationEvent(event, after: eventCount)

        let invalidUIDMoveSession = try await connect(fixture: fixture).session
        let moveEvent = moveEvent(inbox: inbox, archive: archive)
        let moveEventCount = await mutationEventCount(moveEvent)
        do {
          _ = try await invalidUIDMoveSession.move(
            sourceUIDs: [4, 5],
            sourceUIDValidity: 44,
            from: inbox,
            to: archive
          )
          XCTFail("The candidate must reject MOVE UIDs outside the IMAP protocol range.")
        } catch {
          XCTAssertEqual(error as? MailEngineUIDMappingError, .invalidUID)
        }
        await assertExactlyOneNewMutationEvent(moveEvent, after: moveEventCount)
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
    let eventCount = await mutationEventCount(event)
    do {
      _ = try await invalidUIDValiditySession.copy(
        sourceUIDs: [4, 5],
        sourceUIDValidity: 44,
        from: inbox,
        to: archive
      )
      XCTFail("The candidate must reject destination UIDVALIDITY outside the IMAP range.")
    } catch {
      XCTAssertEqual(error as? MailEngineUIDMappingError, .invalidDestinationUIDValidity)
    }
    await assertExactlyOneNewMutationEvent(event, after: eventCount)

    let invalidUIDValidityMoveSession = try await connect(
      fixture: .invalidUIDValidityMapping(uidValidity: invalidUIDValidity)
    ).session
    let moveEvent = moveEvent(inbox: inbox, archive: archive)
    let moveEventCount = await mutationEventCount(moveEvent)
    do {
      _ = try await invalidUIDValidityMoveSession.move(
        sourceUIDs: [4, 5],
        sourceUIDValidity: 44,
        from: inbox,
        to: archive
      )
      XCTFail("The candidate must reject MOVE UIDVALIDITY outside the IMAP range.")
    } catch {
      XCTAssertEqual(error as? MailEngineUIDMappingError, .invalidDestinationUIDValidity)
    }
    await assertExactlyOneNewMutationEvent(moveEvent, after: moveEventCount)
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
        sourceUIDs: [4, 5],
        sourceUIDValidity: invalidUIDValidity,
        from: inbox,
        to: archive
      )
      XCTFail("The candidate must reject source UIDVALIDITY outside the IMAP range.")
    } catch {
      XCTAssertEqual(error as? MailEngineUIDMappingError, .invalidSourceUIDValidity)
    }
    do {
      _ = try await invalidSourceSession.move(
        sourceUIDs: [4, 5],
        sourceUIDValidity: invalidUIDValidity,
        from: inbox,
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
    let first = try await connect(
      fixture: .overlappingUIDMutations,
      connectionID: "mutation-connection-one"
    ).session
    let second = try await connect(
      fixture: .overlappingUIDMutations,
      connectionID: "mutation-connection-two"
    ).session
    let firstArchive = MailEngineMailboxIdentity("First Archive")
    let secondArchive = MailEngineMailboxIdentity("Second Archive")

    async let firstMapping = first.copy(
      sourceUIDs: [19],
      sourceUIDValidity: 44,
      from: inbox,
      to: firstArchive
    )
    async let secondMapping = second.move(
      sourceUIDs: [29],
      sourceUIDValidity: 44,
      from: inbox,
      to: secondArchive
    )
    let (resolvedFirstMapping, resolvedSecondMapping) = try await (firstMapping, secondMapping)

    XCTAssertEqual(resolvedFirstMapping.pairs, [.init(destinationUID: 119, sourceUID: 19)])
    XCTAssertEqual(resolvedSecondMapping.pairs, [.init(destinationUID: 229, sourceUID: 29)])
    await assertOverlappingUIDMutationEvents(
      inbox: inbox,
      firstArchive: firstArchive,
      secondArchive: secondArchive
    )
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
        connectionID == "mutation-connection-one" || connectionID == "mutation-connection-two"
      default:
        false
      }
    }
    let firstEvent = MailEngineQualificationEvent.copyReceived(
      connectionID: "mutation-connection-one",
      sourceUIDs: [19],
      sourceUIDValidity: 44,
      sourceMailbox: inbox,
      destinationMailbox: firstArchive
    )
    let secondEvent = MailEngineQualificationEvent.moveReceived(
      connectionID: "mutation-connection-two",
      sourceUIDs: [29],
      sourceUIDValidity: 44,
      sourceMailbox: inbox,
      destinationMailbox: secondArchive
    )
    XCTAssertEqual(events.count, 2)
    XCTAssertEqual(events.filter { $0 == firstEvent }.count, 1)
    XCTAssertEqual(events.filter { $0 == secondEvent }.count, 1)
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
    inbox: MailEngineMailboxIdentity,
    archive: MailEngineMailboxIdentity
  ) -> MailEngineQualificationEvent {
    .moveReceived(
      connectionID: "connection-a",
      sourceUIDs: [4, 5],
      sourceUIDValidity: 44,
      sourceMailbox: inbox,
      destinationMailbox: archive
    )
  }

  private func mutationEventCount(_ event: MailEngineQualificationEvent) async -> Int {
    await factory.events().filter { $0 == event }.count
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
    after previousEvents: [MailEngineQualificationEvent]
  ) async {
    let currentEvents = await mutationEvents(connectionID: "connection-a")
    XCTAssertEqual(
      currentEvents,
      previousEvents + [event],
      "A malformed UID mapping must not cause any connection-scoped mutation retry."
    )
  }

  private func assertExactlyOneNewMutationEvent(
    _ event: MailEngineQualificationEvent,
    after previousCount: Int
  ) async {
    let currentCount = await mutationEventCount(event)
    XCTAssertEqual(
      currentCount,
      previousCount + 1,
      "A malformed UID mapping must not cause a mutation command retry."
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
        sourceUIDs: [5],
        sourceUIDValidity: 44,
        from: inbox,
        to: archive
      )
      XCTFail("A permanent COPY rejection must be preserved.")
    } catch {
      XCTAssertEqual(
        error as? MailEngineError,
        .protocolRejected(code: "NOPERM", retryable: false)
      )
    }
    let mutationEvents = await factory.events()
    XCTAssertEqual(
      mutationEvents.filter {
        if case .copyReceived(let connectionID, _, _, _, _) = $0 {
          return connectionID == copyConnectionID
        }
        return false
      }.count,
      1,
      "A permanent COPY rejection must not retry."
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
        sourceUIDs: [9],
        sourceUIDValidity: 44,
        from: inbox,
        to: archive
      )
      XCTFail("A permanent MOVE rejection must be preserved.")
    } catch {
      XCTAssertEqual(
        error as? MailEngineError,
        .protocolRejected(code: "NOPERM", retryable: false)
      )
    }
    let mutationEvents = await factory.events()
    XCTAssertEqual(
      mutationEvents.filter {
        if case .moveReceived(let connectionID, _, _, _, _) = $0 {
          return connectionID == moveConnectionID
        }
        return false
      }.count,
      1,
      "A permanent MOVE rejection must not retry."
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
        sourceUIDs: [5],
        sourceUIDValidity: 44,
        from: MailEngineMailboxIdentity("INBOX"),
        to: MailEngineMailboxIdentity("Archive")
      )
      XCTFail("A retryable COPY rejection must be preserved.")
    } catch {
      XCTAssertEqual(
        error as? MailEngineError,
        .protocolRejected(code: "TRYAGAIN", retryable: true)
      )
    }
    let mutationEvents = await factory.events().filter {
      if case .copyReceived(let eventConnectionID, _, _, _, _) = $0 {
        return eventConnectionID == connectionID
      }
      return false
    }
    XCTAssertEqual(mutationEvents.count, 1, "A retryable COPY attempt must remain bounded.")
  }

  private func verifyRetryableMoveRejection() async throws {
    let connectionID = "retryable-move-rejection"
    let session = try await connect(
      fixture: .moveRetryablyRejected,
      connectionID: connectionID
    ).session
    do {
      _ = try await session.move(
        sourceUIDs: [9],
        sourceUIDValidity: 44,
        from: MailEngineMailboxIdentity("INBOX"),
        to: MailEngineMailboxIdentity("Archive")
      )
      XCTFail("A retryable MOVE rejection must be preserved.")
    } catch {
      XCTAssertEqual(
        error as? MailEngineError,
        .protocolRejected(code: "TRYAGAIN", retryable: true)
      )
    }
    let mutationEvents = await factory.events().filter {
      if case .moveReceived(let eventConnectionID, _, _, _, _) = $0 {
        return eventConnectionID == connectionID
      }
      return false
    }
    XCTAssertEqual(mutationEvents.count, 1, "A retryable MOVE attempt must remain bounded.")
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
      sourceUIDs: [9],
      sourceUIDValidity: 44,
      from: inbox,
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
        .movePreservedUnrelatedDeletedUIDs(let eventConnectionID, _):
        eventConnectionID == connectionID
      default:
        false
      }
    }
    let expectedMutation: MailEngineQualificationEvent =
      if hasMove {
        .moveReceived(
          connectionID: connectionID,
          sourceUIDs: [9],
          sourceUIDValidity: 44,
          sourceMailbox: inbox,
          destinationMailbox: archive
        )
      } else {
        .copyReceived(
          connectionID: connectionID,
          sourceUIDs: [9],
          sourceUIDValidity: 44,
          sourceMailbox: inbox,
          destinationMailbox: archive
        )
      }
    XCTAssertEqual(
      profileEvents,
      [
        expectedMutation,
        .movePreservedUnrelatedDeletedUIDs(connectionID: connectionID, uids: [6]),
      ],
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
        sourceUIDs: [9],
        sourceUIDValidity: 44,
        from: inbox,
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
          .moveReceived(let eventConnectionID, _, _, _, _):
          return eventConnectionID == connectionID
        default:
          return false
        }
      },
      "An unsupported move must not create a destination copy."
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
    XCTAssertEqual(mapping.pairs, [.init(destinationUID: 209, sourceUID: 9)])
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
    let connectionID = "idle-recovery-success"
    let recoveringSession = try await connect(
      fixture: .idleDisconnectThenRecover(maximumReconnectTLSVersion: nil),
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
    let eventsAfterDisconnect = await factory.events()
    XCTAssertEqual(
      countIMAPCloses(eventsAfterDisconnect, connectionID: connectionID),
      closesBeforeDisconnect + 1,
      "A disconnected IDLE transport must be closed before recovery."
    )
    let eventCountBeforeRecovery = await factory.events().count
    let recoveredEvents = LockedBox<[MailEngineIdleEvent]>([])
    let handshakeAtCallback = LockedBox<[MailEngineQualificationEvent]>([])
    let recoveryTask = Task {
      try await recoveringSession.idle(mailbox: inbox) { event in
        let events = await factory.events()
        handshakeAtCallback.withValue {
          $0 = Array(events.dropFirst(eventCountBeforeRecovery)).filter {
            $0.belongs(to: connectionID, service: .imap)
          }
        }
        recoveredEvents.withValue { $0.append(event) }
      }
    }
    try await waitForIdleEvents(recoveredEvents, count: 1, timeout: .seconds(2))
    XCTAssertEqual(recoveredEvents.value, [.changedUIDs([10])])
    assertSuccessfulIDLERecoveryHandshake(
      handshakeAtCallback.value,
      connectionID: connectionID
    )
    await assertIdleCancellation(
      recoveryTask,
      failureMessage: "Recovered IDLE must remain active until cancelled."
    )
    try await verifyIDLERecoveryTLSFloor()
  }

  private func assertSuccessfulIDLERecoveryHandshake(
    _ events: [MailEngineQualificationEvent],
    connectionID: String
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
    XCTAssertEqual(
      Array(events.dropFirst()),
      [
        .authenticationStarted(connectionID: connectionID, service: .imap),
        .authenticated(connectionID: connectionID, service: .imap),
      ]
    )
  }

  private func verifyIDLERecoveryTLSFloor() async throws {
    for transportMode in [MailEngineTransportMode.implicitTLS, .startTLS] {
      for legacyVersion in [MailEngineTLSVersion.tls10, .tls11] {
        try await verifyRejectedIDLERecovery(
          transportMode: transportMode,
          legacyVersion: legacyVersion
        )
      }
    }
  }

  private func verifyRejectedIDLERecovery(
    transportMode: MailEngineTransportMode,
    legacyVersion: MailEngineTLSVersion
  ) async throws {
    let connectionID = "idle-reconnect-\(transportMode)-\(legacyVersion)"
    let callbacks = LockedBox<[MailEngineIdleEvent]>([])
    let session = try await connect(
      fixture: .idleDisconnectThenRecover(maximumReconnectTLSVersion: legacyVersion),
      connectionID: connectionID,
      imapTransportMode: transportMode
    ).session
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
    do {
      try await session.idle(mailbox: MailEngineMailboxIdentity("INBOX")) { event in
        callbacks.withValue { $0.append(event) }
      }
      XCTFail("A legacy-TLS IDLE recovery connection must be rejected.")
    } catch {
      XCTAssertEqual(error as? MailEngineError, .tlsVersionUnsupported)
    }
    XCTAssertEqual(callbacks.value, [])
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

  private func verifyOverlappingConnectionIsolation() async throws {
    let inbox = MailEngineMailboxIdentity("INBOX")
    let secondIdleMailbox = MailEngineMailboxIdentity("Team Updates")
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
    try await verifyOverlappingMetadataIsolation(first: first, second: second, inbox: inbox)

    await assertIdleCancellation(
      secondTask,
      failureMessage: "Cancelling the second IDLE must report cancellation."
    )
    await assertSecondIdleCancelled()
    try await verifyNonIdleCancellationIsolation(inbox: inbox)
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
    try? await Task.sleep(for: .milliseconds(50))
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
    let requests = await factory.events().filter { event in
      if case .metadataPageRequested(let connectionID, _, _, _) = event {
        return connectionID == "connection-one" || connectionID == "connection-two"
      }
      return false
    }
    XCTAssertEqual(
      requests,
      [
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
        ),
      ],
      "Each metadata request must reach only its owning account transport."
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
    let firstOutcome = try await first.submit(
      envelope: firstEnvelope,
      rawMessage: firstMessage
    )
    let secondOutcome = try await second.submit(
      envelope: secondEnvelope,
      rawMessage: secondMessage
    )
    XCTAssertEqual(
      firstOutcome,
      .accepted(serverMessageID: "smtp-message-1")
    )
    XCTAssertEqual(
      secondOutcome,
      .accepted(serverMessageID: "smtp-message-1")
    )
    let submissionEvents = await factory.events().filter { event in
      if case .submissionReceived(let connectionID, _, _) = event {
        return connectionID == "connection-one" || connectionID == "connection-two"
      }
      return false
    }
    XCTAssertEqual(
      submissionEvents,
      [
        .submissionReceived(
          connectionID: "connection-one",
          envelope: firstEnvelope,
          rawMessage: firstMessage
        ),
        .submissionReceived(
          connectionID: "connection-two",
          envelope: secondEnvelope,
          rawMessage: secondMessage
        ),
      ],
      "Each SMTP submission must reach only its owning account transport."
    )
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
        for: MailEngineMessageIdentity(mailbox: inbox, uid: 19, uidValidity: 44)
      )
    }
    let secondFetchTask = Task {
      try await second.fetchBodyParts(
        [MailEngineBodyPartSelector("2.TEXT")],
        for: MailEngineMessageIdentity(mailbox: inbox, uid: 29, uidValidity: 44)
      )
    }
    try await factory.waitForBodyFetchStarts(2, timeout: .seconds(2))
    await assertBodyFetchRequests(inbox: inbox)
    await assertBodyFetchCancellation(
      firstFetchTask,
      failureMessage: "Cancelling the first body fetch must report cancellation."
    )
    await assertTaskStillPending(
      secondFetchTask,
      failureMessage: "Cancelling the first body fetch must leave the second fetch active."
    )
    try await assertCancelledBodyFetchPreservesSessions(first, inbox: inbox)

    await assertBodyFetchCancellation(
      secondFetchTask,
      failureMessage: "Cancelling the second body fetch must report cancellation."
    )
    await assertSecondBodyFetchCancelled()
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
  }

  private func assertSecondBodyFetchCancelled() async {
    let events = await factory.events()
    XCTAssertTrue(events.contains(.bodyFetchCancelled(connectionID: "body-fetch-two")))
  }

  private func verifyOverlappingBodyResults(
    inbox: MailEngineMailboxIdentity
  ) async throws {
    let first = try await connect(
      fixture: .successful,
      connectionID: "body-result-one"
    ).session
    let second = try await connect(
      fixture: .successful,
      connectionID: "body-result-two"
    ).session
    let firstSelector = MailEngineBodyPartSelector("1.TEXT")
    let secondSelector = MailEngineBodyPartSelector("2.TEXT")
    async let firstParts = first.fetchBodyParts(
      [firstSelector],
      for: MailEngineMessageIdentity(mailbox: inbox, uid: 19, uidValidity: 44)
    )
    async let secondParts = second.fetchBodyParts(
      [secondSelector],
      for: MailEngineMessageIdentity(mailbox: inbox, uid: 29, uidValidity: 44)
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
      message: MailEngineMessageIdentity(mailbox: inbox, uid: 19, uidValidity: 44),
      selectors: [MailEngineBodyPartSelector("1.TEXT")]
    )
    let secondRequest = MailEngineQualificationEvent.bodyPartsRequested(
      connectionID: "body-fetch-two",
      message: MailEngineMessageIdentity(mailbox: inbox, uid: 29, uidValidity: 44),
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
    try await verifySentAppendRecovery()

    let events = await factory.events()
    XCTAssertEqual(
      events.filter { $0 == .submitted(connectionID: "connection-a") }.count,
      stages.count + 2
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

  private func submitSMTPStages(
    _ stages: [MailEngineSMTPStage],
    session: any MailEngineSession,
    envelope: MailEngineEnvelope,
    rawMessage: Data
  ) async throws -> [MailEngineSMTPOutcome] {
    var observed: [MailEngineSMTPOutcome] = []
    for stage in stages {
      let contentBeforeSubmission = await submissionContentAcceptedMessages(
        connectionID: "connection-a"
      )
      observed.append(
        try await session.submit(
          envelope: envelope,
          rawMessage: rawMessage
        )
      )
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
    }
    return observed
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
    case .authenticationRejectedBeforeSubmission, .dataRejectedBeforeSubmission,
      .recipientRejectedAfterAccepted, .recipientRejectedBeforeSubmission,
      .senderRejectedBeforeSubmission, .transportUnavailableBeforeSubmission:
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
        .dataRejectedBeforeSubmission(code: 451),
        .dataRejectedBeforeSubmission(code: 550),
        .finalResponse(code: 451),
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
        .notSubmitted(.dataRejected(code: 451)),
        .notSubmitted(.dataRejected(code: 550)),
        .transientlyRejected(code: 451),
        .permanentlyRejected(code: 550),
        .ambiguous,
        .accepted(serverMessageID: "smtp-message-1"),
        .accepted(serverMessageID: nil),
      ]
    )
  }

  private func verifySMTPCancellation() async throws {
    let preservedConnectionID = "pre-content-cancellation-peer"
    let preservedSession = try await connect(
      fixture: .successful,
      connectionID: preservedConnectionID
    ).session
    let cancelledSession = try await connect(
      fixture: .smtpStages([.cancelledBeforeSubmission]),
      connectionID: "pre-content-cancellation"
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
    let contentEvents = await factory.events().filter {
      if case .submissionReceived(
        connectionID: "pre-content-cancellation",
        envelope: _,
        rawMessage: _
      ) = $0 {
        return true
      }
      return false
    }
    XCTAssertEqual(contentEvents, [])
    try await assertSMTPPeerRemainsUsable(
      preservedSession,
      connectionID: preservedConnectionID
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
    let preservedConnectionID = "post-content-cancellation-peer"
    let preservedSession = try await connect(
      fixture: .successful,
      connectionID: preservedConnectionID
    ).session
    let session = try await connect(
      fixture: .smtpStages([.cancelledAfterMessageContent])
    ).session
    let envelope = MailEngineEnvelope(
      recipients: ["first-recipient@example.com", "second-recipient@example.com"],
      sender: "sender@example.com"
    )
    let rawMessage = Data("Subject: Post-content cancellation\r\n\r\nPrivate body".utf8)
    let submissionsBefore = await submissionEvents(connectionID: "connection-a")
    let contentAcceptancesBeforeSubmission = await submissionContentAcceptedMessages(
      connectionID: "connection-a"
    ).count
    let submissionTask = Task {
      try await session.submit(
        envelope: envelope,
        rawMessage: rawMessage
      )
    }
    try await waitForSubmissionContent(
      after: contentAcceptancesBeforeSubmission,
      connectionID: "connection-a"
    )
    submissionTask.cancel()
    await assertPostContentCancellationResult(submissionTask)
    await assertPostContentSubmission(
      envelope: envelope,
      rawMessage: rawMessage,
      previousSubmissions: submissionsBefore
    )
    try await assertSMTPPeerRemainsUsable(
      preservedSession,
      connectionID: preservedConnectionID
    )
  }

  private func assertPostContentCancellationResult(
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
      XCTFail("Timed out waiting for post-content SMTP cancellation.")
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
    previousSubmissions: [MailEngineQualificationEvent]
  ) async {
    let submissionsAfter = await submissionEvents(connectionID: "connection-a")
    XCTAssertEqual(
      submissionsAfter,
      previousSubmissions + [
        .submissionReceived(
          connectionID: "connection-a",
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

  private func assertSMTPPeerRemainsUsable(
    _ session: any MailEngineSession,
    connectionID: String
  ) async throws {
    await assertNoServiceClose(
      connectionID: connectionID,
      failureMessage: "Cancelling one SMTP submission must preserve other account transports."
    )
    let envelope = MailEngineEnvelope(
      recipients: ["peer-recipient@example.com"],
      sender: "peer-sender@example.com"
    )
    let rawMessage = Data("Subject: Peer remains active\r\n\r\nBody".utf8)
    let submissionsBefore = await submissionEvents(connectionID: connectionID)
    let outcome = try await session.submit(
      envelope: envelope,
      rawMessage: rawMessage
    )
    XCTAssertEqual(outcome, .accepted(serverMessageID: "smtp-message-1"))
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
      "The peer submission must use the peer account's SMTP transport."
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
      MailEngineMessageIdentity(mailbox: sentMailbox, uid: 11, uidValidity: 45)
    )
    await assertSentRecoveryEvents(rawMessage: rawMessage, sentMailbox: sentMailbox)
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
    XCTAssertTrue(
      events.contains(
        .submissionReceived(
          connectionID: "connection-a",
          envelope: MailEngineEnvelope(
            recipients: ["recipient@example.com"],
            sender: "sender@example.com"
          ),
          rawMessage: rawMessage
        )
      )
    )
  }

  func verifyProtocolTracePrivacy() async throws {
    let sink = RecordingMailEngineProductionLogSink()
    let logger = PrivacyPreservingMailEngineLogger(sink: sink)
    let (oauthSession, passwordSession) = try await connectPrivacySessions(logger: logger)
    try await exercisePrivateOperations(
      oauthSession: oauthSession,
      passwordSession: passwordSession
    )
    await oauthSession.close()
    await passwordSession.close()

    await assertCandidateOutputContainsNoQualificationSecrets()
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
      for: MailEngineMessageIdentity(mailbox: privateMailbox, uid: 19, uidValidity: 44)
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
      MailEngineMessageIdentity(mailbox: sentMailbox, uid: 11, uidValidity: 45)
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
    inspectedOutput.append(decodedBase64Records(in: candidateOutput))
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
  }

  private func decodedBase64Records(in output: Data) -> Data {
    let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=".utf8)
    var decodedRecords = Data()
    var token = Data()

    func appendDecodedToken() {
      let assignmentIndex = token.indices.last { index in
        guard token[index] == UInt8(ascii: "=") else { return false }
        let valueStart = token.index(after: index)
        return valueStart < token.endIndex
          && token[valueStart...].contains { $0 != UInt8(ascii: "=") }
      }
      var encodedToken =
        assignmentIndex.map { Data(token[token.index(after: $0)...]) } ?? token
      guard encodedToken.count >= 4 else {
        token.removeAll(keepingCapacity: true)
        return
      }
      let remainder = encodedToken.count % 4
      guard remainder != 1 else {
        token.removeAll(keepingCapacity: true)
        return
      }
      if remainder > 0 {
        encodedToken.append(
          contentsOf: repeatElement(UInt8(ascii: "="), count: 4 - remainder)
        )
      }
      guard let decoded = Data(base64Encoded: encodedToken) else {
        token.removeAll(keepingCapacity: true)
        return
      }
      decodedRecords.append(decoded)
      decodedRecords.append(0)
      token.removeAll(keepingCapacity: true)
    }

    for byte in output {
      if alphabet.contains(byte) {
        token.append(byte)
      } else {
        appendDecodedToken()
      }
    }
    appendDecodedToken()
    return decodedRecords
  }

  func verifyConnectionLifecycle() async throws {
    let session = try await connect(fixture: .inFlightOperationsUntilClosed).session
    let preservedSession = try await connect(
      fixture: .successful,
      connectionID: "connection-b"
    ).session
    let callbacks = LockedBox<[MailEngineIdleEvent]>([])
    let idleTask = Task {
      try await session.idle(mailbox: MailEngineMailboxIdentity("INBOX")) { event in
        callbacks.withValue { $0.append(event) }
      }
    }
    let bodyFetchTask = Task {
      _ = try await session.fetchBodyParts(
        [MailEngineBodyPartSelector("1.TEXT")],
        for: MailEngineMessageIdentity(
          mailbox: MailEngineMailboxIdentity("INBOX"),
          uid: 9,
          uidValidity: 44
        )
      )
    }
    let submissionTask = inFlightSubmissionTask(session)
    try await factory.waitForIdleStarts(1, timeout: .seconds(2))
    try await factory.waitForBodyFetchStarts(1, timeout: .seconds(2))
    try await factory.waitForSubmissionStarts(1, timeout: .seconds(2))
    try await waitForIdleEvents(callbacks, count: 1, timeout: .seconds(2))
    let callbacksBeforeClose = callbacks.value
    await session.close()
    await assertInFlightOperationClosed(idleTask)
    await assertInFlightOperationClosed(bodyFetchTask)
    await assertInFlightOperationClosed(submissionTask)
    assertNoIdleCallbacks(callbacks, after: callbacksBeforeClose)
    await assertNoSubmissionContentAccepted(connectionID: "connection-a")
    try await assertSessionRemainsUsable(preservedSession, connectionID: "connection-b")
    let eventsBeforeClosedOperations = await factory.events()
    await assertClosedOperations(session)
    try? await Task.sleep(for: .milliseconds(50))
    let events = await factory.events()
    XCTAssertEqual(
      events,
      eventsBeforeClosedOperations,
      "Closed-session operations must not reach the server fixture."
    )
    assertNoIdleCallbacks(callbacks, after: callbacksBeforeClose)
    XCTAssertTrue(events.contains(.closed(connectionID: "connection-a")))
    assertServiceTeardownEvents(events)
    await preservedSession.close()
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
    _ = try await session.loadMetadataPage(
      mailbox: MailEngineMailboxIdentity("INBOX"),
      beforeUID: nil,
      limit: 1
    )
    await assertNoServiceClose(
      connectionID: connectionID,
      failureMessage: "Closing one session must preserve other connected sessions."
    )
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

  private func assertClosedOperations(_ session: any MailEngineSession) async {
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
  }

  private func assertServiceTeardownEvents(_ events: [MailEngineQualificationEvent]) {
    XCTAssertTrue(
      events.contains(.serviceClosed(connectionID: "connection-a", service: .imap))
    )
    XCTAssertTrue(
      events.contains(.serviceClosed(connectionID: "connection-a", service: .smtp))
    )
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

  func waitForSubmissionStarts(_ count: Int, timeout: Duration) async throws {
    try await state.waitForSubmissionStarts(count, timeout: timeout)
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

  func waitForMutationStarts(_ count: Int, timeout: Duration) async throws {
    try await waitForEvents(count, timeout: timeout) {
      switch $0 {
      case .copyReceived, .moveReceived:
        true
      default:
        false
      }
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
        await state.record(
          .serviceClosed(connectionID: configuration.connectionID, service: service)
        )
        throw MailEngineError.tlsVersionUnsupported
      }
      negotiatedVersion = maximumTLSVersion
    } else if case .reducedCapabilityMove = fixture {
      negotiatedVersion = .tls12
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
    transportSecurity: [MailEngineService: MailEngineTLSVersion]
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
    return MailEngineConnectionSnapshot(
      capabilities: capabilities,
      mailboxes: mailboxes,
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
    await state.record(.serviceClosed(connectionID: connectionID, service: .imap))
    await state.record(.serviceClosed(connectionID: connectionID, service: .smtp))
    await state.record(.closed(connectionID: connectionID))
  }

  func copy(
    sourceUIDs: [Int64],
    sourceUIDValidity: Int64,
    from sourceMailbox: MailEngineMailboxIdentity,
    to destinationMailbox: MailEngineMailboxIdentity
  ) async throws -> MailEngineUIDMapping {
    try ensureOpen()
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
    if case .overlappingUIDMutations = fixture {
      try await state.waitForMutationStarts(2, timeout: .seconds(2))
    }
    if case .copyOutcomeUnknown = fixture {
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
    if case .malformedCopyUIDMapping = fixture {
      return MailEngineReportedUIDMapping(
        destinationUIDValidity: 91,
        destinationUIDs: [104],
        sourceUIDs: [4]
      )
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
    return MailEngineReportedUIDMapping(
      destinationUIDValidity: 91,
      destinationUIDs: sourceUIDs.map { $0 + 100 },
      sourceUIDs: sourceUIDs
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
        try ensureOpen()
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
    try ensureOpen()
    idleAttempt += 1
    await state.record(.idleStarted(connectionID: connectionID, mailbox: mailbox))
    if case .idleDisconnectThenRecover(let maximumReconnectTLSVersion) = fixture {
      guard idleAttempt > 1 else {
        await state.record(.serviceClosed(connectionID: connectionID, service: .imap))
        throw MailEngineError.connectionClosed
      }
      if let maximumReconnectTLSVersion, maximumReconnectTLSVersion < .tls12 {
        await state.record(.serviceClosed(connectionID: connectionID, service: .imap))
        throw MailEngineError.tlsVersionUnsupported
      }
      await state.record(
        .tlsEstablished(
          connectionID: connectionID,
          service: .imap,
          version: maximumReconnectTLSVersion ?? .tls13
        )
      )
      await state.record(.authenticationStarted(connectionID: connectionID, service: .imap))
      await state.record(.authenticated(connectionID: connectionID, service: .imap))
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

  func loadMetadataPage(
    mailbox: MailEngineMailboxIdentity,
    beforeUID: Int64?,
    limit: Int
  ) async throws -> MailEngineMetadataPage {
    try ensureOpen()
    await state.record(
      .metadataPageRequested(
        connectionID: connectionID,
        mailbox: mailbox,
        beforeUID: beforeUID,
        limit: limit
      )
    )
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
    if case .overlappingUIDMutations = fixture {
      try await state.waitForMutationStarts(2, timeout: .seconds(2))
    }
    if case .reducedCapabilityMove = fixture {
      await state.record(
        .movePreservedUnrelatedDeletedUIDs(connectionID: connectionID, uids: [6])
      )
    }
    if case .moveOutcomeUnknown = fixture {
      throw MailEngineError.operationOutcomeUnknown
    }
    if case .movePermanentlyRejected = fixture {
      throw MailEngineError.protocolRejected(code: "NOPERM", retryable: false)
    }
    if case .moveRetryablyRejected = fixture {
      throw MailEngineError.protocolRejected(code: "TRYAGAIN", retryable: true)
    }
    let reported = reportedMoveUIDMapping(sourceUIDs: sourceUIDs)
    return try MailEngineUIDMapping.validated(
      sourceMailbox: sourceMailbox,
      sourceUIDValidity: sourceUIDValidity,
      destinationMailbox: destinationMailbox,
      requestedSourceUIDs: sourceUIDs,
      reported: reported
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
    if case .malformedMoveUIDMapping = fixture {
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
    if case .mismatchedUIDMappingCardinality = fixture {
      return MailEngineReportedUIDMapping(
        destinationUIDValidity: 92,
        destinationUIDs: [204],
        sourceUIDs: sourceUIDs
      )
    }
    return MailEngineReportedUIDMapping(
      destinationUIDValidity: 92,
      destinationUIDs: sourceUIDs.map { $0 + 200 },
      sourceUIDs: sourceUIDs
    )
  }

  func submit(
    envelope: MailEngineEnvelope,
    rawMessage: Data
  ) async throws -> MailEngineSMTPOutcome {
    try ensureOpen()
    if case .smtpStages(let stages) = fixture, smtpStageIndex < stages.count {
      defer { smtpStageIndex += 1 }
      return try await submitSMTPStage(
        stages[smtpStageIndex],
        envelope: envelope,
        rawMessage: rawMessage
      )
    }
    if case .inFlightOperationsUntilClosed = fixture {
      await state.record(.submissionStarted(connectionID: connectionID))
      while true {
        try ensureOpen()
        try await Task.sleep(for: .milliseconds(10))
      }
    }
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
    return .accepted(serverMessageID: "smtp-message-1")
  }

  private func submitSMTPStage(
    _ stage: MailEngineSMTPStage,
    envelope: MailEngineEnvelope,
    rawMessage: Data
  ) async throws -> MailEngineSMTPOutcome {
    if case .cancelledBeforeSubmission = stage {
      await state.record(.submissionStarted(connectionID: connectionID))
      do {
        while true {
          try Task.checkCancellation()
          try await Task.sleep(for: .milliseconds(10))
        }
      } catch is CancellationError {
        throw MailEngineError.cancelled
      }
    }
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
      do {
        while true {
          try Task.checkCancellation()
          try await Task.sleep(for: .milliseconds(10))
        }
      } catch is CancellationError {
        return .ambiguous
      }
    }
    if transmitsMessageContent(stage) {
      await state.record(
        .submissionContentAccepted(connectionID: connectionID, rawMessage: rawMessage)
      )
    }
    return classifySMTPStage(stage)
  }

  private func transmitsMessageContent(_ stage: MailEngineSMTPStage) -> Bool {
    switch stage {
    case .accepted, .connectionLostAfterSubmission, .finalResponse:
      true
    case .authenticationRejectedBeforeSubmission, .cancelledAfterMessageContent,
      .cancelledBeforeSubmission, .dataRejectedBeforeSubmission, .recipientRejectedAfterAccepted,
      .recipientRejectedBeforeSubmission, .senderRejectedBeforeSubmission,
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
    case .cancelledBeforeSubmission:
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
        try ensureOpen()
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
