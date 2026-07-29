import Foundation
import XCTest

@testable import unwired_mail

// swiftlint:disable file_length type_body_length

final class MailEngineQualificationTests: XCTestCase {
  func testSetupTransportAuthenticationAndCapabilitiesContract() async throws {
    try await makeContract().verifySetupTransportAuthenticationAndCapabilities()
  }

  func testRejectsInsecureTransportAndInvalidServerIdentityContract() async {
    await makeContract().verifyTransportAndServerIdentityFailures()
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
  case connectionFailure(MailEngineError)
  case idleDisconnectThenRecover
  case idleUntilCancelled
  case maximumTLS(MailEngineTLSVersion)
  case sentAppendFailsOnce
  case smtpOutcomes([MailEngineSMTPOutcome])
  case successful
}

enum MailEngineQualificationEvent: Equatable, Sendable {
  case authenticated(connectionID: String)
  case closed(connectionID: String)
  case idleCancelled(connectionID: String)
  case idleStarted(connectionID: String)
  case sentAppend(connectionID: String)
  case submitted(connectionID: String)
  case tlsEstablished(connectionID: String, version: MailEngineTLSVersion)
}

struct MailEngineQualificationContract {
  let factory: any MailEngineQualificationCandidateFactory

  func verifySetupTransportAuthenticationAndCapabilities() async throws {
    let connection = try await connect(fixture: .successful)

    XCTAssertEqual(connection.snapshot.tlsVersion, .tls13)
    XCTAssertEqual(
      connection.snapshot.capabilities,
      [.idle, .move, .specialUse, .uidPlus]
    )
    XCTAssertEqual(
      connection.snapshot.mailboxes,
      [
        MailEngineMailbox(identity: MailEngineMailboxIdentity("INBOX"), specialUses: []),
        MailEngineMailbox(
          identity: MailEngineMailboxIdentity("Sent"),
          specialUses: [.sent]
        ),
      ]
    )
    let events = await factory.events()
    XCTAssertEqual(
      events,
      [
        .tlsEstablished(connectionID: "connection-a", version: .tls13),
        .authenticated(connectionID: "connection-a"),
      ]
    )
  }

  func verifyTransportAndServerIdentityFailures() async {
    for transportMode in [MailEngineTransportMode.implicitTLS, .startTLS] {
      for legacyVersion in [MailEngineTLSVersion.tls10, .tls11] {
        await assertConnectionFails(
          fixture: .maximumTLS(legacyVersion),
          transportMode: transportMode,
          expectedError: .tlsVersionUnsupported
        )
      }
    }

    for error in [
      MailEngineError.certificateRejected,
      .serverIdentityMismatch,
      .startTLSRejected,
      .authenticationRejected,
    ] {
      await assertConnectionFails(
        fixture: .connectionFailure(error),
        expectedError: error
      )
    }
    let events = await factory.events()
    XCTAssertEqual(
      events,
      [.tlsEstablished(connectionID: "connection-a", version: .tls13)]
    )
  }

  func verifyUIDMappings() async throws {
    let session = try await connect(fixture: .successful).session
    let inbox = MailEngineMailboxIdentity("INBOX")
    let archive = MailEngineMailboxIdentity("Archive")

    let copy = try await session.copy(
      sourceUIDs: [5, 4],
      from: inbox,
      to: archive
    )
    let move = try await session.move(
      sourceUIDs: [9, 8],
      from: inbox,
      to: archive
    )

    XCTAssertEqual(copy.sourceMailbox, inbox)
    XCTAssertEqual(copy.destinationMailbox, archive)
    XCTAssertEqual(copy.destinationUIDValidity, 91)
    XCTAssertEqual(
      copy.pairs,
      [
        MailEngineUIDPair(destinationUID: 105, sourceUID: 5),
        MailEngineUIDPair(destinationUID: 104, sourceUID: 4),
      ]
    )
    XCTAssertEqual(move.destinationUIDValidity, 92)
    XCTAssertEqual(
      move.pairs,
      [
        MailEngineUIDPair(destinationUID: 209, sourceUID: 9),
        MailEngineUIDPair(destinationUID: 208, sourceUID: 8),
      ]
    )
    verifyInvalidUIDMappings(inbox: inbox, archive: archive)
  }

  private func verifyInvalidUIDMappings(
    inbox: MailEngineMailboxIdentity,
    archive: MailEngineMailboxIdentity
  ) {
    XCTAssertThrowsError(
      try MailEngineUIDMapping.validated(
        sourceMailbox: inbox,
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

    let first = try await connect(
      fixture: .idleUntilCancelled,
      connectionID: "connection-one"
    ).session
    let second = try await connect(
      fixture: .idleUntilCancelled,
      connectionID: "connection-two"
    ).session
    let firstTask = Task { try await first.idle(mailbox: inbox) { _ in } }
    let secondTask = Task { try await second.idle(mailbox: inbox) { _ in } }
    await factory.waitForIdleStarts(4)

    firstTask.cancel()
    _ = await firstTask.result
    await Task.yield()
    let cancellations = await factory.events().filter {
      if case .idleCancelled = $0 { return true }
      return false
    }
    XCTAssertEqual(cancellations, [.idleCancelled(connectionID: "connection-one")])
    XCTAssertFalse(secondTask.isCancelled)

    secondTask.cancel()
    _ = await secondTask.result
  }

  func verifySMTPAndSentAppend() async throws {
    let outcomes: [MailEngineSMTPOutcome] = [
      .notSubmitted(.transportUnavailable),
      .transientlyRejected(code: 451),
      .permanentlyRejected(code: 550),
      .ambiguous,
      .accepted(serverMessageID: "smtp-message-1"),
    ]
    let session = try await connect(fixture: .smtpOutcomes(outcomes)).session
    var observed: [MailEngineSMTPOutcome] = []
    for _ in outcomes {
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
    XCTAssertEqual(observed, outcomes)
    try await verifySentAppendRecovery()

    let events = await factory.events()
    XCTAssertEqual(events.filter { $0 == .submitted(connectionID: "connection-a") }.count, 6)
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

    XCTAssertEqual(sink.events, [.connected])
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
    connectionID: String = "connection-a"
  ) async throws -> (
    snapshot: MailEngineConnectionSnapshot,
    session: any MailEngineSession
  ) {
    try await factory.makeEngine(fixture: fixture).connect(
      configuration: configuration(connectionID: connectionID),
      logger: PrivacyPreservingMailEngineLogger(sink: RecordingMailEngineProductionLogSink())
    )
  }

  private func assertConnectionFails(
    fixture: MailEngineQualificationFixture,
    transportMode: MailEngineTransportMode = .implicitTLS,
    expectedError: MailEngineError
  ) async {
    do {
      _ = try await factory.makeEngine(fixture: fixture).connect(
        configuration: configuration(transportMode: transportMode),
        logger: PrivacyPreservingMailEngineLogger(sink: RecordingMailEngineProductionLogSink())
      )
      XCTFail("The candidate should reject this connection.")
    } catch {
      XCTAssertEqual(error as? MailEngineError, expectedError)
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
    logger.recordProtocolTrace(Self.privateProtocolTrace)

    if case .connectionFailure(let error) = fixture {
      if error == .authenticationRejected {
        await state.record(
          .tlsEstablished(connectionID: configuration.connectionID, version: .tls13)
        )
      }
      throw error
    }
    let negotiatedVersion: MailEngineTLSVersion
    if case .maximumTLS(let maximumTLSVersion) = fixture {
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
        version: negotiatedVersion
      )
    )
    await state.record(.authenticated(connectionID: configuration.connectionID))
    logger.record(.connected)

    return (
      snapshot(tlsVersion: negotiatedVersion),
      ScriptedMailEngineSession(
        connectionID: configuration.connectionID,
        fixture: fixture,
        state: state
      )
    )
  }

  private static var privateProtocolTrace: Data {
    Data(
      """
      A1 AUTHENTICATE private-bearer-token
      * LIST () "/" "private-mailbox"
      Subject: private message
      """.utf8
    )
  }

  private func snapshot(tlsVersion: MailEngineTLSVersion) -> MailEngineConnectionSnapshot {
    MailEngineConnectionSnapshot(
      capabilities: [.idle, .move, .specialUse, .uidPlus],
      mailboxes: [
        MailEngineMailbox(identity: MailEngineMailboxIdentity("INBOX"), specialUses: []),
        MailEngineMailbox(
          identity: MailEngineMailboxIdentity("Sent"),
          specialUses: [.sent]
        ),
      ],
      tlsVersion: tlsVersion
    )
  }
}

private actor ScriptedMailEngineSession: MailEngineSession {
  let connectionID: String
  let fixture: MailEngineQualificationFixture
  let state: ScriptedMailEngineState
  private var appendAttempt = 0
  private var idleAttempt = 0
  private var isClosed = false
  private var smtpOutcomeIndex = 0

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
    from sourceMailbox: MailEngineMailboxIdentity,
    to destinationMailbox: MailEngineMailboxIdentity
  ) async throws -> MailEngineUIDMapping {
    try ensureOpen()
    return try MailEngineUIDMapping.validated(
      sourceMailbox: sourceMailbox,
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
    for _: MailEngineMessageIdentity
  ) async throws -> [MailEngineBodyPart] {
    try ensureOpen()
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
      try await withTaskCancellationHandler {
        while true {
          try Task.checkCancellation()
          try await Task.sleep(nanoseconds: 10_000_000)
        }
      } onCancel: {
        Task {
          await state.record(.idleCancelled(connectionID: connectionID))
        }
      }
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
          identity: MailEngineMessageIdentity(mailbox: mailbox, uid: $0, uidValidity: 44),
          internalDate: Date(timeIntervalSince1970: TimeInterval($0)),
          rfcMessageID: "<\($0)@example.com>"
        )
      },
      nextOlderUID: hasMore ? selectedUIDs.last : nil,
      uidValidity: 44
    )
  }

  func move(
    sourceUIDs: [Int64],
    from sourceMailbox: MailEngineMailboxIdentity,
    to destinationMailbox: MailEngineMailboxIdentity
  ) async throws -> MailEngineUIDMapping {
    try ensureOpen()
    return try MailEngineUIDMapping.validated(
      sourceMailbox: sourceMailbox,
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
    if case .smtpOutcomes(let outcomes) = fixture, smtpOutcomeIndex < outcomes.count {
      defer { smtpOutcomeIndex += 1 }
      return outcomes[smtpOutcomeIndex]
    }
    return .accepted(serverMessageID: "smtp-message-1")
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
