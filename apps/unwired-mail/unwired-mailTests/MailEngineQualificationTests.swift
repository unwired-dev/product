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
  func events() async -> [MailEngineQualificationEvent]
  func makeEngine(
    fixture: MailEngineQualificationFixture
  ) -> any MailEngine
  func waitForIdleStarts(_ count: Int) async
}

enum MailEngineQualificationFixture: Sendable {
  case connectionFailure(service: MailEngineService, error: MailEngineError)
  case copyOutcomeUnknown
  case idleDisconnectThenRecover
  case idleUntilCancelled
  case maximumTLS(service: MailEngineService, version: MailEngineTLSVersion)
  case sentAppendFailsOnce
  case smtpStages([MailEngineSMTPStage])
  case successful
  case uidValidityReset
  case xoauth2Challenge(service: MailEngineService)
}

enum MailEngineSMTPStage: Sendable {
  case accepted(serverMessageID: String?)
  case authenticationRejectedBeforeSubmission
  case connectionLostAfterSubmission
  case finalResponse(code: Int)
  case recipientRejectedBeforeSubmission(code: Int)
  case transportUnavailableBeforeSubmission
}

enum MailEngineQualificationEvent: Equatable, Sendable {
  case authenticationChallengeAnswered(connectionID: String, service: MailEngineService)
  case authenticationStarted(connectionID: String, service: MailEngineService)
  case authenticated(connectionID: String, service: MailEngineService)
  case closed(connectionID: String)
  case idleCancelled(connectionID: String)
  case idleStarted(connectionID: String)
  case sentAppend(connectionID: String)
  case submitted(connectionID: String)
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
    case .closed, .idleCancelled, .idleStarted, .sentAppend, .submitted:
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
      transportMode: .implicitTLS
    )
    let startTLSConnection = try await connect(
      fixture: .successful,
      authorization: .xoauth2(
        username: "oauth-success@example.com",
        accessToken: "oauth-success-token"
      ),
      connectionID: "starttls-success",
      transportMode: .startTLS
    )
    try await verifyXOAUTH2Challenge(service: .imap, connectionID: "xoauth2-imap-challenge")
    try await verifyXOAUTH2Challenge(service: .smtp, connectionID: "xoauth2-smtp-challenge")
    verifySuccessfulSnapshot(implicitConnection.snapshot)
    XCTAssertEqual(
      startTLSConnection.snapshot.transportSecurity,
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
    for connectionID in ["implicit-success", "starttls-success"] {
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
    for service in [MailEngineService.imap, .smtp] {
      for transportMode in [MailEngineTransportMode.implicitTLS, .startTLS] {
        let tls12Connection = try await connect(
          fixture: .maximumTLS(service: service, version: .tls12),
          connectionID: "tls12-\(service)-\(transportMode)",
          transportMode: transportMode
        )
        XCTAssertEqual(tls12Connection.snapshot.transportSecurity[service], .tls12)
        for legacyVersion in [MailEngineTLSVersion.tls10, .tls11] {
          await assertConnectionFails(
            fixture: .maximumTLS(service: service, version: legacyVersion),
            failedService: service,
            transportMode: transportMode,
            expectedError: .tlsVersionUnsupported
          )
        }
      }
    }

    for service in [MailEngineService.imap, .smtp] {
      for error in [
        MailEngineError.certificateRejected,
        .serverIdentityMismatch,
      ] {
        await assertConnectionFails(
          fixture: .connectionFailure(service: service, error: error),
          failedService: service,
          expectedError: error
        )
      }
      await assertConnectionFails(
        fixture: .connectionFailure(service: service, error: .startTLSRejected),
        failedService: service,
        transportMode: .startTLS,
        expectedError: .startTLSRejected
      )
      await assertConnectionFails(
        fixture: .connectionFailure(service: service, error: .authenticationRejected),
        authorization: .xoauth2(
          username: "oauth-rejected@example.com",
          accessToken: "oauth-rejected-token"
        ),
        failedService: service,
        expectedError: .authenticationRejected
      )
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
    verifyInvalidUIDMappings(inbox: inbox, archive: archive)
    try await verifyUnknownMutationOutcome(inbox: inbox, archive: archive)
    try await verifyUIDValidityReset(inbox: inbox, archive: archive)
  }

  private func verifyUnknownMutationOutcome(
    inbox: MailEngineMailboxIdentity,
    archive: MailEngineMailboxIdentity
  ) async throws {
    let session = try await connect(fixture: .copyOutcomeUnknown).session
    do {
      _ = try await session.copy(
        sourceUIDs: [5],
        sourceUIDValidity: 44,
        from: inbox,
        to: archive
      )
      XCTFail("An indeterminate copy outcome must be classified for reconciliation.")
    } catch {
      XCTAssertEqual(error as? MailEngineError, .operationOutcomeUnknown)
    }
  }

  private func verifyUIDValidityReset(
    inbox: MailEngineMailboxIdentity,
    archive: MailEngineMailboxIdentity
  ) async throws {
    let session = try await connect(fixture: .uidValidityReset).session
    let pageBeforeReset = try await session.loadMetadataPage(
      mailbox: inbox,
      beforeUID: nil,
      limit: 1
    )
    let events = LockedBox<[MailEngineIdleEvent]>([])

    try await session.idle(mailbox: inbox) { event in
      events.withValue { $0.append(event) }
    }

    XCTAssertEqual(events.value, [.mailboxReset(uidValidity: 99)])
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
  ) {
    XCTAssertThrowsError(
      try MailEngineUIDMapping.validated(
        sourceMailbox: inbox,
        sourceUIDValidity: 44,
        destinationMailbox: archive,
        requestedSourceUIDs: [4, 5],
        reported: MailEngineReportedUIDMapping(
          destinationUIDValidity: 91,
          destinationUIDs: [40],
          sourceUIDs: [4]
        )
      )
    ) { error in
      XCTAssertEqual(error as? MailEngineUIDMappingError, .mismatchedSourceUIDs)
    }
    XCTAssertThrowsError(
      try MailEngineUIDMapping.validated(
        sourceMailbox: inbox,
        sourceUIDValidity: 44,
        destinationMailbox: archive,
        requestedSourceUIDs: [4, 5],
        reported: MailEngineReportedUIDMapping(
          destinationUIDValidity: 91,
          destinationUIDs: [40, 40],
          sourceUIDs: [4, 5]
        )
      )
    ) { error in
      XCTAssertEqual(error as? MailEngineUIDMappingError, .repeatedUID)
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

    XCTAssertEqual(firstPage.messages.map(\.identity.uid), [9, 8])
    XCTAssertEqual(firstPage.uidValidity, 44)
    XCTAssertEqual(firstPage.nextOlderUID, 8)
    XCTAssertEqual(historicalPage.messages.map(\.identity.uid), [7])
    XCTAssertNil(historicalPage.nextOlderUID)

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
    try await recoveringSession.idle(mailbox: inbox) { event in
      recoveredEvents.withValue { $0.append(event) }
    }
    XCTAssertEqual(recoveredEvents.value, [.changedUIDs([10])])
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
    await factory.waitForIdleStarts(4)

    firstTask.cancel()
    switch await firstTask.result {
    case .success:
      XCTFail("Cancelling IDLE must report cancellation.")
    case .failure(let error):
      XCTAssertEqual(error as? MailEngineError, .cancelled)
    }
    let cancellations = await idleCancellationEvents()
    XCTAssertEqual(cancellations, [.idleCancelled(connectionID: "connection-one")])
    let secondPage = try await second.loadMetadataPage(
      mailbox: inbox,
      beforeUID: nil,
      limit: 1
    )
    XCTAssertEqual(secondPage.messages.map(\.identity.uid), [9])
    XCTAssertEqual(firstCallbacks.value, [])
    XCTAssertEqual(secondCallbacks.value, [])

    secondTask.cancel()
    switch await secondTask.result {
    case .success:
      XCTFail("Cancelling the second IDLE must report cancellation.")
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

  func verifySMTPAndSentAppend() async throws {
    let stages: [MailEngineSMTPStage] = [
      .transportUnavailableBeforeSubmission,
      .authenticationRejectedBeforeSubmission,
      .recipientRejectedBeforeSubmission(code: 451),
      .finalResponse(code: 451),
      .finalResponse(code: 550),
      .connectionLostAfterSubmission,
      .accepted(serverMessageID: "smtp-message-1"),
    ]
    let expectedOutcomes: [MailEngineSMTPOutcome] = [
      .notSubmitted(.transportUnavailable),
      .notSubmitted(.authentication),
      .notSubmitted(.recipientRejected(code: 451)),
      .transientlyRejected(code: 451),
      .permanentlyRejected(code: 550),
      .ambiguous,
      .accepted(serverMessageID: "smtp-message-1"),
    ]
    let session = try await connect(fixture: .smtpStages(stages)).session
    var observed: [MailEngineSMTPOutcome] = []
    for _ in stages {
      observed.append(
        await session.submit(
          envelope: MailEngineEnvelope(
            recipients: ["recipient@example.com"],
            sender: "sender@example.com"
          ),
          rawMessage: Data("Subject: Contract\r\n\r\nBody".utf8)
        )
      )
    }
    XCTAssertEqual(observed, expectedOutcomes)
    try await verifySentAppendRecovery()

    let events = await factory.events()
    XCTAssertEqual(events.filter { $0 == .submitted(connectionID: "connection-a") }.count, 8)
    XCTAssertEqual(events.filter { $0 == .sentAppend(connectionID: "connection-a") }.count, 2)
  }

  private func verifySentAppendRecovery() async throws {
    let sentRecoverySession = try await connect(fixture: .sentAppendFailsOnce).session
    let accepted = await sentRecoverySession.submit(
      envelope: MailEngineEnvelope(
        recipients: ["recipient@example.com"],
        sender: "sender@example.com"
      ),
      rawMessage: Data("Subject: Sent recovery\r\n\r\nBody".utf8)
    )
    XCTAssertEqual(accepted, .accepted(serverMessageID: "smtp-message-1"))
    do {
      _ = try await sentRecoverySession.appendToSent(
        Data("message".utf8),
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
      Data("message".utf8),
      mailbox: MailEngineMailboxIdentity("Sent")
    )
    XCTAssertEqual(appended.uidValidity, 45)
    XCTAssertEqual(appended.uid, 11)
  }

  func verifyProtocolTracePrivacy() async throws {
    let sink = RecordingMailEngineProductionLogSink()
    let logger = PrivacyPreservingMailEngineLogger(sink: sink)

    _ = try await factory.makeEngine(fixture: .successful).connect(
      configuration: configuration(
        authorization: .xoauth2(
          username: "private-mailbox@example.com",
          accessToken: "private-bearer-token"
        )
      ),
      logger: logger
    )
    _ = try await factory.makeEngine(fixture: .successful).connect(
      configuration: configuration(
        authorization: .password(
          username: "private-password-mailbox@example.com",
          password: "private-password"
        )
      ),
      logger: logger
    )

    XCTAssertEqual(sink.events, [.connected, .connected])
  }

  func verifyConnectionLifecycle() async throws {
    let session = try await connect(fixture: .successful).session
    await session.close()

    do {
      _ = try await session.loadMetadataPage(
        mailbox: MailEngineMailboxIdentity("INBOX"),
        beforeUID: nil,
        limit: 1
      )
      XCTFail("A closed session should reject further work.")
    } catch {
      XCTAssertEqual(error as? MailEngineError, .connectionClosed)
    }
    let events = await factory.events()
    XCTAssertTrue(events.contains(.closed(connectionID: "connection-a")))
  }

  private func connect(
    fixture: MailEngineQualificationFixture,
    authorization: MailEngineAuthorization = .password(
      username: "private-mailbox@example.com",
      password: "private-password"
    ),
    connectionID: String = "connection-a",
    transportMode: MailEngineTransportMode = .implicitTLS
  ) async throws -> (
    snapshot: MailEngineConnectionSnapshot,
    session: any MailEngineSession
  ) {
    try await factory.makeEngine(fixture: fixture).connect(
      configuration: configuration(
        authorization: authorization,
        connectionID: connectionID,
        transportMode: transportMode
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
    transportMode: MailEngineTransportMode = .implicitTLS,
    expectedError: MailEngineError
  ) async {
    let connectionID = "expected-failure-\(await factory.events().count)"
    do {
      _ = try await factory.makeEngine(fixture: fixture).connect(
        configuration: configuration(
          authorization: authorization,
          connectionID: connectionID,
          transportMode: transportMode
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
  }

  private func configuration(
    authorization: MailEngineAuthorization = .password(
      username: "private-mailbox@example.com",
      password: "private-password"
    ),
    connectionID: String = "connection-a",
    transportMode: MailEngineTransportMode = .implicitTLS
  ) -> MailEngineConfiguration {
    MailEngineConfiguration(
      authorization: authorization,
      connectionID: connectionID,
      imapEndpoint: MailEngineEndpoint(
        hostname: "imap.example.com",
        port: transportMode == .implicitTLS ? 993 : 143,
        transportMode: transportMode
      ),
      smtpEndpoint: MailEngineEndpoint(
        hostname: "smtp.example.com",
        port: transportMode == .implicitTLS ? 465 : 587,
        transportMode: transportMode
      )
    )
  }
}

private final class ScriptedMailEngineQualificationFactory:
  MailEngineQualificationCandidateFactory,
  @unchecked Sendable
{
  private let state = ScriptedMailEngineState()

  func events() async -> [MailEngineQualificationEvent] {
    await state.events
  }

  func makeEngine(fixture: MailEngineQualificationFixture) -> any MailEngine {
    ScriptedMailEngine(fixture: fixture, state: state)
  }

  func waitForIdleStarts(_ count: Int) async {
    await state.waitForIdleStarts(count)
  }
}

private actor ScriptedMailEngineState {
  private(set) var events: [MailEngineQualificationEvent] = []
  private var idleWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

  func record(_ event: MailEngineQualificationEvent) {
    events.append(event)
    let idleStartCount = events.filter {
      if case .idleStarted = $0 { return true }
      return false
    }.count
    let ready = idleWaiters.filter { $0.count <= idleStartCount }
    idleWaiters.removeAll { $0.count <= idleStartCount }
    for waiter in ready {
      waiter.continuation.resume()
    }
  }

  func waitForIdleStarts(_ count: Int) async {
    let currentCount = events.filter {
      if case .idleStarted = $0 { return true }
      return false
    }.count
    guard currentCount < count else { return }
    await withCheckedContinuation { continuation in
      idleWaiters.append((count: count, continuation: continuation))
    }
  }
}

private struct ScriptedMailEngine: MailEngine {
  let fixture: MailEngineQualificationFixture
  let state: ScriptedMailEngineState

  func connect(
    configuration: MailEngineConfiguration,
    logger: any MailEngineLogging
  ) async throws -> (snapshot: MailEngineConnectionSnapshot, session: any MailEngineSession) {
    logger.recordProtocolTrace(privateProtocolTrace(authorization: configuration.authorization))

    var transportSecurity: [MailEngineService: MailEngineTLSVersion] = [:]
    for service in [MailEngineService.imap, .smtp] {
      let negotiatedVersion = try await establish(
        service: service,
        configuration: configuration
      )
      transportSecurity[service] = negotiatedVersion
    }

    logger.record(.connected)

    return (
      snapshot(transportSecurity: transportSecurity),
      ScriptedMailEngineSession(
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
    MailEngineConnectionSnapshot(
      capabilities: [.idle, .move, .specialUse, .uidPlus],
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
  let connectionID: String
  let fixture: MailEngineQualificationFixture
  let state: ScriptedMailEngineState
  private var appendAttempt = 0
  private var currentUIDValidity: Int64 = 44
  private var idleAttempt = 0
  private var isClosed = false
  private var smtpStageIndex = 0

  init(
    connectionID: String,
    fixture: MailEngineQualificationFixture,
    state: ScriptedMailEngineState
  ) {
    self.connectionID = connectionID
    self.fixture = fixture
    self.state = state
  }

  func appendToSent(
    _: Data,
    mailbox: MailEngineMailboxIdentity
  ) async throws -> MailEngineMessageIdentity {
    try ensureOpen()
    appendAttempt += 1
    await state.record(.sentAppend(connectionID: connectionID))
    if case .sentAppendFailsOnce = fixture, appendAttempt == 1 {
      throw MailEngineError.protocolRejected(code: "TRYAGAIN", retryable: true)
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
    guard sourceUIDValidity == currentUIDValidity else {
      throw MailEngineError.staleMessageIdentity
    }
    if case .copyOutcomeUnknown = fixture {
      throw MailEngineError.operationOutcomeUnknown
    }
    return try MailEngineUIDMapping.validated(
      sourceMailbox: sourceMailbox,
      sourceUIDValidity: sourceUIDValidity,
      destinationMailbox: destinationMailbox,
      requestedSourceUIDs: sourceUIDs,
      reported: MailEngineReportedUIDMapping(
        destinationUIDValidity: 91,
        destinationUIDs: sourceUIDs.map { $0 + 100 },
        sourceUIDs: sourceUIDs
      )
    )
  }

  func fetchBodyParts(
    _ selectors: Set<MailEngineBodyPartSelector>,
    for message: MailEngineMessageIdentity
  ) async throws -> [MailEngineBodyPart] {
    try ensureOpen()
    guard message.uidValidity == currentUIDValidity else {
      throw MailEngineError.staleMessageIdentity
    }
    return selectors.sorted { $0.rawValue < $1.rawValue }.map {
      MailEngineBodyPart(data: Data("body-\($0.rawValue)".utf8), selector: $0)
    }
  }

  func idle(
    mailbox _: MailEngineMailboxIdentity,
    onEvent: @escaping @Sendable (MailEngineIdleEvent) async -> Void
  ) async throws {
    try ensureOpen()
    idleAttempt += 1
    await state.record(.idleStarted(connectionID: connectionID))
    if case .idleDisconnectThenRecover = fixture {
      guard idleAttempt > 1 else { throw MailEngineError.connectionClosed }
      await onEvent(.changedUIDs([10]))
      return
    }
    if case .idleUntilCancelled = fixture {
      do {
        while true {
          try Task.checkCancellation()
          try await Task.sleep(nanoseconds: 10_000_000)
        }
      } catch is CancellationError {
        await state.record(.idleCancelled(connectionID: connectionID))
        throw MailEngineError.cancelled
      }
    }
    if case .uidValidityReset = fixture {
      currentUIDValidity = 99
      await onEvent(.mailboxReset(uidValidity: currentUIDValidity))
    }
  }

  func loadMetadataPage(
    mailbox: MailEngineMailboxIdentity,
    beforeUID: Int64?,
    limit: Int
  ) async throws -> MailEngineMetadataPage {
    try ensureOpen()
    let availableUIDs = [Int64(9), 8, 7].filter { uid in
      beforeUID.map { uid < $0 } ?? true
    }
    let selectedUIDs = Array(availableUIDs.prefix(limit))
    let hasMore = availableUIDs.count > selectedUIDs.count
    return MailEngineMetadataPage(
      messages: selectedUIDs.map {
        MailEngineMessageMetadata(
          flags: [],
          identity: MailEngineMessageIdentity(
            mailbox: mailbox,
            uid: $0,
            uidValidity: currentUIDValidity
          ),
          internalDate: Date(timeIntervalSince1970: TimeInterval($0)),
          rfcMessageID: "<\($0)@example.com>"
        )
      },
      nextOlderUID: hasMore ? selectedUIDs.last : nil,
      uidValidity: currentUIDValidity
    )
  }

  func move(
    sourceUIDs: [Int64],
    sourceUIDValidity: Int64,
    from sourceMailbox: MailEngineMailboxIdentity,
    to destinationMailbox: MailEngineMailboxIdentity
  ) async throws -> MailEngineUIDMapping {
    try ensureOpen()
    guard sourceUIDValidity == currentUIDValidity else {
      throw MailEngineError.staleMessageIdentity
    }
    return try MailEngineUIDMapping.validated(
      sourceMailbox: sourceMailbox,
      sourceUIDValidity: sourceUIDValidity,
      destinationMailbox: destinationMailbox,
      requestedSourceUIDs: sourceUIDs,
      reported: MailEngineReportedUIDMapping(
        destinationUIDValidity: 92,
        destinationUIDs: sourceUIDs.map { $0 + 200 },
        sourceUIDs: sourceUIDs
      )
    )
  }

  func submit(
    envelope _: MailEngineEnvelope,
    rawMessage _: Data
  ) async -> MailEngineSMTPOutcome {
    guard !isClosed else { return .notSubmitted(.transportUnavailable) }
    await state.record(.submitted(connectionID: connectionID))
    if case .smtpStages(let stages) = fixture, smtpStageIndex < stages.count {
      defer { smtpStageIndex += 1 }
      return classifySMTPStage(stages[smtpStageIndex])
    }
    return .accepted(serverMessageID: "smtp-message-1")
  }

  private func classifySMTPStage(_ stage: MailEngineSMTPStage) -> MailEngineSMTPOutcome {
    switch stage {
    case .accepted(let serverMessageID):
      .accepted(serverMessageID: serverMessageID)
    case .authenticationRejectedBeforeSubmission:
      .notSubmitted(.authentication)
    case .connectionLostAfterSubmission:
      .ambiguous
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
