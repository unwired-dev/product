import Foundation
import Testing

@testable import unwired_mail

// swiftlint:disable file_length

@MainActor
@Suite(.serialized)
// swiftlint:disable:next type_body_length
final class OutboxDeliveryServiceTests {
  private let immediateHandoffDelay: UInt64 = 0
  private let connection = MailboxConnection(
    authorizationState: .authorized,
    capabilities: .gmail,
    connectedAt: 1_781_200_000_000,
    displayName: "sender@example.com",
    id: MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .gmail,
        value: "gmail-user-001"
      )
    ),
    lastVerifiedAt: 1_781_200_000_100,
    productAccountId: ProductAccountId("product-account-001"),
    trustedDeviceId: "trusted-device-001",
    updatedAt: 1_781_200_000_200
  )
  private let graphConnection = MailboxConnection(
    authorizationState: .authorized,
    capabilities: .microsoftGraph,
    connectedAt: 1_781_200_000_000,
    displayName: "sender@example.com",
    id: MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .microsoftGraph,
        value: "graph-user-001"
      )
    ),
    lastVerifiedAt: 1_781_200_000_100,
    productAccountId: ProductAccountId("product-account-001"),
    trustedDeviceId: "trusted-device-001",
    updatedAt: 1_781_200_000_200
  )
  private let standardsMailConnection = MailboxConnection(
    authorizationState: .authorized,
    capabilities: .standardsMail(
      engineCapabilities: [.idle, .uidPlus],
      roleMappings: Dictionary(
        uniqueKeysWithValues: CanonicalMailboxRole.allCases.map { ($0, $0.rawValue) }
      )
    ),
    connectedAt: 1_781_200_000_000,
    displayName: "sender@example.com",
    id: MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .imapSMTP,
        value: "standards-mail-user-001"
      )
    ),
    lastVerifiedAt: 1_781_200_000_100,
    productAccountId: ProductAccountId("product-account-001"),
    trustedDeviceId: "trusted-device-001",
    updatedAt: 1_781_200_000_200
  )
  private let exchangeWebServicesConnection = MailboxConnection(
    authorizationState: .authorized,
    capabilities: .exchangeWebServices,
    connectedAt: 1_781_200_000_000,
    displayName: "sender@corp.example",
    id: MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .exchangeWebServices,
        value: "ews-user-001"
      )
    ),
    lastVerifiedAt: 1_781_200_000_100,
    productAccountId: ProductAccountId("product-account-001"),
    trustedDeviceId: "trusted-device-001",
    updatedAt: 1_781_200_000_200
  )

  @Test
  func scheduledSendManagementDiscoversRemoteStateAndFencesHandoff() async throws {
    let record = scheduledSendRecord(revision: 1)
    let snapshot = ScheduledSendPayloadSnapshot(
      acknowledgement: ScheduledSendPayloadAcknowledgement(
        payloadIdentifier: "payload-1",
        updatedAt: 11
      ),
      record: record
    )
    let payloads = InMemoryScheduledSendPayloadSync(snapshots: [snapshot])
    let transport = ScheduledSendManagementTransportSpy(
      status: scheduledSendStatus(for: snapshot, claimPhase: .handingOff)
    )
    let service = ScheduledSendService(
      outboxService: OutboxDeliveryService(store: InMemoryOutboxDeliveryStore()),
      payloadSync: payloads,
      transport: transport
    )

    let item = try #require(await service.managedItems(session: session).first)
    #expect(item.state == .sending)
    await #expect(throws: ScheduledSendManagementError.editUnavailable) {
      try await service.beginEditing(item, session: session)
    }
    #expect(await transport.beginEditCallCount() == 0)
  }

  @Test
  func scheduledSendManagementSelectsTheOperationalRevision() async throws {
    let current = ScheduledSendPayloadSnapshot(
      acknowledgement: ScheduledSendPayloadAcknowledgement(
        payloadIdentifier: "payload-1",
        updatedAt: 11
      ),
      record: scheduledSendRecord(revision: 1)
    )
    let orphan = ScheduledSendPayloadSnapshot(
      acknowledgement: ScheduledSendPayloadAcknowledgement(
        payloadIdentifier: "payload-2",
        updatedAt: 12
      ),
      record: scheduledSendRecord(revision: 2)
    )
    let service = ScheduledSendService(
      outboxService: OutboxDeliveryService(store: InMemoryOutboxDeliveryStore()),
      payloadSync: InMemoryScheduledSendPayloadSync(snapshots: [current, orphan]),
      transport: ScheduledSendManagementTransportSpy(
        status: scheduledSendStatus(for: current, claimPhase: nil)
      )
    )

    let item = try #require(await service.managedItems(session: session).first)

    #expect(item.record.revision == 1)
    #expect(item.payload == current.acknowledgement)
  }

  @Test
  func scheduledSendEditCreatesAValidatedRevisionAndNewOutboxAttempt() async throws {
    let record = scheduledSendRecord(revision: 1)
    let snapshot = ScheduledSendPayloadSnapshot(
      acknowledgement: ScheduledSendPayloadAcknowledgement(
        payloadIdentifier: "payload-1",
        updatedAt: 11
      ),
      record: record
    )
    let payloads = InMemoryScheduledSendPayloadSync(snapshots: [snapshot])
    let transport = ScheduledSendManagementTransportSpy(
      status: scheduledSendStatus(for: snapshot, claimPhase: nil)
    )
    let store = InMemoryOutboxDeliveryStore()
    let outbox = OutboxDeliveryService(store: store)
    let service = ScheduledSendService(
      now: { Date(timeIntervalSince1970: 1_800_000_000) },
      outboxService: outbox,
      payloadSync: payloads,
      transport: transport
    )
    let item = try #require(await service.managedItems(session: session).first)
    let editSession = try await service.beginEditing(item, session: session)
    let dueAt = Date(timeIntervalSince1970: 1_800_007_200)

    let replacement = try await service.reschedule(
      editSession,
      message: message,
      connection: connection,
      dueAt: dueAt,
      originalTimeZoneIdentifier: "Europe/Prague",
      session: session,
      undoSendDelayNanoseconds: 10_000_000_000,
      provider: { _, _, _ in },
      reconcile: { _, _ in .notSent }
    )

    #expect(replacement.record.revision == 2)
    #expect(replacement.record.connectionId == connection.id)
    let attempt = try #require(await outbox.actionableItems(session: session).first)
    #expect(attempt.scheduledSendRevision == 2)
    #expect(attempt.scheduledSendId == record.scheduleId)
    #expect(await transport.rescheduledRevision() == 2)
  }

  private func scheduledSendRecord(revision: Int) -> ScheduledSendRecord {
    let dueAt: Int64 = 1_800_003_600_000
    return ScheduledSendRecord(
      connectionId: connection.id,
      createdAtMilliseconds: 1_800_000_000_000,
      deadlineAtMilliseconds: dueAt + 24 * 60 * 60 * 1_000,
      draftId: UUID(uuidString: "00000000-0000-0000-0000-000000000381")!,
      dueAtMilliseconds: dueAt,
      message: message,
      originatingDeviceId: session.trustedDeviceId,
      originalTimeZoneIdentifier: "Europe/Prague",
      profileId: MailProfileId.defaultProfile(productAccountId: session.productAccountId),
      revision: revision,
      scheduleId: UUID(uuidString: "00000000-0000-0000-0000-000000000382")!
    )
  }

  private func scheduledSendStatus(
    for snapshot: ScheduledSendPayloadSnapshot,
    claimPhase: ScheduledSendClaimPhase?
  ) -> ScheduledSendOperationalStatus {
    ScheduledSendOperationalStatus(
      claimPhase: claimPhase,
      deadlineAt: snapshot.record.deadlineAtMilliseconds,
      dueAt: snapshot.record.dueAtMilliseconds,
      encryptedPayloadIdentifier: snapshot.acknowledgement.payloadIdentifier,
      encryptedPayloadUpdatedAt: snapshot.acknowledgement.updatedAt,
      revision: snapshot.record.revision,
      scheduleId: snapshot.record.scheduleId.uuidString.lowercased(),
      state: .active
    )
  }
  private let message = OutgoingMessage(
    body: "Queued while offline",
    recipient: "reader@example.com",
    subject: "Offline delivery"
  )
  private let session = ProductAccountSessionSnapshot(
    appleUserIdentifier: "apple-user-001",
    identityToken: "product-token",
    productAccountId: "product-account-001",
    trustedDeviceId: "trusted-device-001"
  )

  @Test(.bug(id: 384))
  func standardsMailScheduledSendAdmissionPreservesItsPayloadAndConnection() async throws {
    let clock = LockedOutboxClock(Date(timeIntervalSince1970: 1_800_000_000))
    let deliveries = DeliveryCounter()
    let payloads = InMemoryScheduledSendPayloadSync(snapshots: [])
    let transport = ScheduledSendClaimTransportSpy()
    let outbox = OutboxDeliveryService(
      now: { clock.now() },
      scheduledSendTransport: transport,
      store: InMemoryOutboxDeliveryStore()
    )
    let service = ScheduledSendService(
      now: { clock.now() },
      outboxService: outbox,
      payloadSync: payloads,
      transport: transport
    )
    let draftId = try #require(
      UUID(uuidString: "00000000-0000-0000-0000-000000000384")
    )

    let attempt = try await service.schedule(
      message,
      connection: standardsMailConnection,
      draftId: draftId,
      profileId: MailProfileId.defaultProfile(productAccountId: session.productAccountId),
      originalTimeZoneIdentifier: "Europe/Prague",
      dueAt: clock.now().addingTimeInterval(60),
      session: session,
      undoSendDelayNanoseconds: 10_000_000_000,
      provider: { _, _, _ in await deliveries.increment() },
      reconcile: { _, _ in .notSent }
    )
    let payload = try #require(await payloads.list(session: session).first)

    #expect(attempt.mailboxConnectionId == standardsMailConnection.id)
    #expect(attempt.message == message)
    #expect(payload.record.connectionId == standardsMailConnection.id)
    #expect(payload.record.message == message)
    #expect(await deliveries.currentValue() == 0)

    clock.advance(by: 70)
    try await outbox.resume(
      connections: [standardsMailConnection],
      session: session,
      provider: { _, _, _ in await deliveries.increment() },
      reconcile: { _, _ in .notSent }
    )
    #expect(await deliveries.currentValue() == 1)

    await outbox.suspend(productAccountId: session.productAccountId)
  }

  @Test(.bug(id: 384))
  func standardsMailScheduledSendUsesTheProvidersUnknownLimitPolicy() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let outbox = OutboxDeliveryService(store: InMemoryOutboxDeliveryStore())
    let service = ScheduledSendService(
      now: { now },
      outboxService: outbox,
      payloadSync: InMemoryScheduledSendPayloadSync(snapshots: []),
      transport: ScheduledSendClaimTransportSpy()
    )
    let messageAboveGraphLimit = OutgoingMessage(
      body: String(repeating: "a", count: 3 * 1_024 * 1_024),
      recipient: message.recipient,
      subject: message.subject
    )

    _ = try await service.schedule(
      messageAboveGraphLimit,
      connection: standardsMailConnection,
      draftId: UUID(),
      profileId: MailProfileId.defaultProfile(productAccountId: session.productAccountId),
      originalTimeZoneIdentifier: "Europe/Prague",
      dueAt: now.addingTimeInterval(60),
      session: session,
      undoSendDelayNanoseconds: 0,
      provider: { _, _, _ in Issue.record("Delivery must wait for the scheduled instant.") },
      reconcile: { _, _ in .notSent }
    )

    await outbox.suspend(productAccountId: session.productAccountId)
  }

  @Test(.bug(id: 383))
  func exchangeWebServicesScheduledSendAdmissionPreservesItsPayloadAndConnection() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let payloads = InMemoryScheduledSendPayloadSync(snapshots: [])
    let transport = ScheduledSendClaimTransportSpy()
    let outbox = OutboxDeliveryService(
      now: { now },
      scheduledSendTransport: transport,
      store: InMemoryOutboxDeliveryStore()
    )
    let service = ScheduledSendService(
      now: { now },
      outboxService: outbox,
      payloadSync: payloads,
      transport: transport
    )

    let attempt = try await service.schedule(
      message,
      connection: exchangeWebServicesConnection,
      draftId: UUID(uuidString: "00000000-0000-0000-0000-000000000383")!,
      profileId: MailProfileId.defaultProfile(productAccountId: session.productAccountId),
      originalTimeZoneIdentifier: "Europe/Prague",
      dueAt: now.addingTimeInterval(60),
      session: session,
      undoSendDelayNanoseconds: 10_000_000_000,
      provider: { _, _, _ in Issue.record("Delivery must wait for the scheduled instant.") },
      reconcile: { _, _ in .notSent }
    )
    let payload = try #require(await payloads.list(session: session).first)

    #expect(attempt.mailboxConnectionId == exchangeWebServicesConnection.id)
    #expect(attempt.message == message)
    #expect(payload.record.connectionId == exchangeWebServicesConnection.id)
    #expect(payload.record.message == message)

    await outbox.suspend(productAccountId: session.productAccountId)
  }

  @Test(.bug(id: 383))
  func exchangeWebServicesScheduledSendWakeRestoresAndDeliversTheAttempt() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let dueAtMilliseconds = Int64(now.addingTimeInterval(-60).timeIntervalSince1970 * 1_000)
    let record = ScheduledSendRecord(
      connectionId: exchangeWebServicesConnection.id,
      createdAtMilliseconds: dueAtMilliseconds - 60_000,
      deadlineAtMilliseconds: dueAtMilliseconds + 24 * 60 * 60 * 1_000,
      draftId: UUID(uuidString: "00000000-0000-0000-0000-000000000381")!,
      dueAtMilliseconds: dueAtMilliseconds,
      message: message,
      originatingDeviceId: session.trustedDeviceId,
      originalTimeZoneIdentifier: "Europe/Prague",
      profileId: MailProfileId.defaultProfile(productAccountId: session.productAccountId),
      revision: 1,
      scheduleId: UUID(uuidString: "00000000-0000-0000-0000-000000000383")!
    )
    let payload = ScheduledSendPayloadSnapshot(
      acknowledgement: ScheduledSendPayloadAcknowledgement(
        payloadIdentifier: "payload-ews-wake",
        updatedAt: dueAtMilliseconds - 30_000
      ),
      record: record
    )
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let transport = ScheduledSendClaimTransportSpy()
    let mailService = ScheduledSendMailboxRoutingSpy(
      connections: [exchangeWebServicesConnection]
    )
    let handler = ScheduledSendWakeupHandler(
      mailService: mailService,
      outboxService: OutboxDeliveryService(
        now: { now },
        scheduledSendTransport: transport,
        store: InMemoryOutboxDeliveryStore()
      ),
      payloadSync: InMemoryScheduledSendPayloadSync(snapshots: [payload]),
      scheduledSendTransport: transport,
      sessionStore: sessionStore
    )

    let handled = try await handler.handle(userInfo: [
      "provider": "scheduled-send",
      "revision": NSNumber(value: record.revision),
      "scheduleId": record.scheduleId.uuidString,
    ])

    #expect(handled)
    #expect(mailService.sentConnectionIds == [exchangeWebServicesConnection.id])
    #expect(await transport.events() == ["claim", "advance", "complete"])
  }

  @Test(.bug(id: 382))
  func microsoftGraphScheduledSendAdmissionPreservesItsPayloadAndConnection() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let payloads = InMemoryScheduledSendPayloadSync(snapshots: [])
    let transport = ScheduledSendClaimTransportSpy()
    let outbox = OutboxDeliveryService(
      now: { now },
      scheduledSendTransport: transport,
      store: InMemoryOutboxDeliveryStore()
    )
    let service = ScheduledSendService(
      now: { now },
      outboxService: outbox,
      payloadSync: payloads,
      transport: transport
    )

    let attempt = try await service.schedule(
      message,
      connection: graphConnection,
      draftId: UUID(uuidString: "00000000-0000-0000-0000-000000000382")!,
      profileId: MailProfileId.defaultProfile(productAccountId: session.productAccountId),
      originalTimeZoneIdentifier: "Europe/Prague",
      dueAt: now.addingTimeInterval(60),
      session: session,
      undoSendDelayNanoseconds: 10_000_000_000,
      provider: { _, _, _ in Issue.record("Delivery must wait for the scheduled instant.") },
      reconcile: { _, _ in .notSent }
    )
    let payload = try #require(await payloads.list(session: session).first)

    #expect(attempt.mailboxConnectionId == graphConnection.id)
    #expect(attempt.message == message)
    #expect(payload.record.connectionId == graphConnection.id)
    #expect(payload.record.message == message)

    await outbox.suspend(productAccountId: session.productAccountId)
  }

  @Test(.bug(id: 382))
  func microsoftGraphScheduledSendWakeRestoresAndDeliversTheAttempt() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let dueAtMilliseconds = Int64(now.addingTimeInterval(-60).timeIntervalSince1970 * 1_000)
    let record = ScheduledSendRecord(
      connectionId: graphConnection.id,
      createdAtMilliseconds: dueAtMilliseconds - 60_000,
      deadlineAtMilliseconds: dueAtMilliseconds + 24 * 60 * 60 * 1_000,
      draftId: UUID(uuidString: "00000000-0000-0000-0000-000000000381")!,
      dueAtMilliseconds: dueAtMilliseconds,
      message: message,
      originatingDeviceId: session.trustedDeviceId,
      originalTimeZoneIdentifier: "Europe/Prague",
      profileId: MailProfileId.defaultProfile(productAccountId: session.productAccountId),
      revision: 1,
      scheduleId: UUID(uuidString: "00000000-0000-0000-0000-000000000382")!
    )
    let payload = ScheduledSendPayloadSnapshot(
      acknowledgement: ScheduledSendPayloadAcknowledgement(
        payloadIdentifier: "payload-graph-wake",
        updatedAt: dueAtMilliseconds - 30_000
      ),
      record: record
    )
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let transport = ScheduledSendClaimTransportSpy()
    let mailService = ScheduledSendMailboxRoutingSpy(connections: [graphConnection])
    let handler = ScheduledSendWakeupHandler(
      mailService: mailService,
      outboxService: OutboxDeliveryService(
        now: { now },
        scheduledSendTransport: transport,
        store: InMemoryOutboxDeliveryStore()
      ),
      payloadSync: InMemoryScheduledSendPayloadSync(snapshots: [payload]),
      scheduledSendTransport: transport,
      sessionStore: sessionStore
    )

    let handled = try await handler.handle(userInfo: [
      "provider": "scheduled-send",
      "revision": NSNumber(value: record.revision),
      "scheduleId": record.scheduleId.uuidString,
    ])

    #expect(handled)
    #expect(mailService.sentConnectionIds == [graphConnection.id])
    #expect(await transport.events() == ["claim", "advance", "complete"])
  }

  @Test(.bug(id: 382))
  func microsoftGraphScheduledSendAdmissionUsesTheGraphTransferLimit() async {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let transport = ScheduledSendClaimTransportSpy()
    let outbox = OutboxDeliveryService(
      now: { now },
      scheduledSendTransport: transport,
      store: InMemoryOutboxDeliveryStore()
    )
    let service = ScheduledSendService(
      now: { now },
      outboxService: outbox,
      payloadSync: InMemoryScheduledSendPayloadSync(snapshots: []),
      transport: transport
    )
    let oversizedMessage = OutgoingMessage(
      body: String(repeating: "a", count: 3 * 1_024 * 1_024),
      recipient: message.recipient,
      subject: message.subject
    )

    await #expect(throws: ScheduledSendAdmissionError.sizeLimitExceeded) {
      _ = try await service.schedule(
        oversizedMessage,
        connection: graphConnection,
        draftId: UUID(),
        profileId: MailProfileId.defaultProfile(productAccountId: session.productAccountId),
        originalTimeZoneIdentifier: "Europe/Prague",
        dueAt: now.addingTimeInterval(60),
        session: session,
        undoSendDelayNanoseconds: 10_000_000_000,
        provider: { _, _, _ in },
        reconcile: { _, _ in .notSent }
      )
    }
  }

  @Test(.bug(id: 383))
  func dueScheduledSendWaitsForTheBusyConnectionsCurrentPass() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let gate = DeliveryHandoffGate()
    let deliveries = DeliveryCounter()
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      now: { now },
      store: InMemoryOutboxDeliveryStore()
    )
    let provider: OutboxDeliveryPerformer = { message, _, _ in
      await deliveries.increment()
      if message.subject == "Offline delivery" {
        await gate.waitForRelease()
      }
    }
    let currentPass = Task {
      try await service.enqueue(
        message,
        connection: connection,
        session: session,
        provider: provider,
        reconcile: { _, _ in .notSent }
      )
    }
    await gate.waitUntilStarted()
    let firstScheduledPass = Task {
      try await enqueueDueScheduled(
        "First scheduled", service: service, provider: provider, now: now
      )
    }
    let secondScheduledPass = Task {
      try await enqueueDueScheduled(
        "Second scheduled", service: service, provider: provider, now: now
      )
    }
    while try await service.items(session: session).count < 3 {
      await Task.yield()
    }

    #expect(await deliveries.currentValue() == 1)
    await gate.release()
    _ = try await currentPass.value
    let firstScheduledAttempt = try await firstScheduledPass.value
    let secondScheduledAttempt = try await secondScheduledPass.value

    #expect(firstScheduledAttempt.state == .sent)
    #expect(secondScheduledAttempt.state == .sent)
    #expect(await deliveries.currentValue() == 3)
  }

  @Test(.bug(id: 383))
  func dueScheduledSendRetainsRetryCleanupAfterATransientFailure() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let delivery = TransientSecondMessageDelivery()
    let service = OutboxDeliveryService(
      now: { now },
      retryDelayNanoseconds: { _ in 0 },
      store: InMemoryOutboxDeliveryStore()
    )

    let firstPass = try await service.enqueueScheduled(
      OutgoingMessage(body: "Retry", recipient: message.recipient, subject: "Second"),
      connection: connection,
      session: session,
      scheduleId: UUID(),
      revision: 1,
      dueAt: now,
      deadline: now.addingTimeInterval(24 * 60 * 60),
      undoSendDelayNanoseconds: 0,
      provider: { message, _, _ in try await delivery.deliver(message) },
      reconcile: { _, _ in .notSent }
    )
    _ = await service.waitForScheduledRetries()
    let remainingAttempts = try await service.items(session: session)
    let attemptCount = await delivery.attemptCount()

    #expect(firstPass.state == .retrying)
    #expect(remainingAttempts.isEmpty)
    #expect(attemptCount == 2)
  }

  @Test(.bug(id: 380))
  func testScheduledSendClaimFencePrecedesProviderHandoff() async throws {
    let clock = LockedOutboxClock(Date(timeIntervalSince1970: 1_800_000_000))
    let store = InMemoryOutboxDeliveryStore()
    let transport = ScheduledSendClaimTransportSpy()
    let dueAt = clock.now().addingTimeInterval(60)
    let queuedService = OutboxDeliveryService(
      now: { clock.now() },
      scheduledSendTransport: transport,
      store: store
    )
    _ = try await queuedService.enqueueScheduled(
      message,
      connection: connection,
      session: session,
      scheduleId: UUID(),
      revision: 1,
      dueAt: dueAt,
      deadline: dueAt.addingTimeInterval(24 * 60 * 60),
      undoSendDelayNanoseconds: 0,
      provider: { _, _, _ in Issue.record("The original process should be suspended.") },
      reconcile: { _, _ in .notSent }
    )
    await queuedService.suspend(productAccountId: session.productAccountId)
    clock.advance(by: 60)

    let restartedService = OutboxDeliveryService(
      now: { clock.now() },
      scheduledSendTransport: transport,
      store: store
    )
    try await restartedService.resume(
      connections: [connection],
      session: session,
      provider: { _, _, _ in await transport.recordProviderHandoff() },
      reconcile: { _, _ in .notSent }
    )

    #expect(await transport.events() == ["claim", "advance", "provider", "complete"])
  }

  @Test
  func testScheduledSendNeverHandsOffEarlyAndResumesAfterRestart() async throws {
    let clock = LockedOutboxClock(Date(timeIntervalSince1970: 1_800_000_000))
    let deliveries = DeliveryCounter()
    let store = InMemoryOutboxDeliveryStore()
    let dueAt = clock.now().addingTimeInterval(10 * 60)
    let queuedService = OutboxDeliveryService(now: { clock.now() }, store: store)
    let attempt = try await queuedService.enqueueScheduled(
      message,
      connection: connection,
      session: session,
      scheduleId: UUID(),
      revision: 1,
      dueAt: dueAt,
      deadline: dueAt.addingTimeInterval(24 * 60 * 60),
      undoSendDelayNanoseconds: UndoSendWindow.tenSeconds.nanoseconds,
      provider: { _, _, _ in Issue.record("The original process should be suspended.") },
      reconcile: { _, _ in .notSent }
    )
    await queuedService.suspend(productAccountId: session.productAccountId)

    #expect(attempt.scheduledSendAtMilliseconds == Int64(dueAt.timeIntervalSince1970 * 1_000))
    #expect(
      attempt.providerHandoffNotBeforeMilliseconds
        == Int64(dueAt.timeIntervalSince1970 * 1_000) + 10_000
    )

    clock.advance(by: 9 * 60)
    let restartedService = OutboxDeliveryService(now: { clock.now() }, store: store)
    try await restartedService.resume(
      connections: [connection],
      session: session,
      provider: { _, _, _ in await deliveries.increment() },
      reconcile: { _, _ in .notSent }
    )
    #expect(await deliveries.currentValue() == 0)
    await restartedService.suspend(productAccountId: session.productAccountId)

    clock.advance(by: 71)
    let dueService = OutboxDeliveryService(now: { clock.now() }, store: store)
    try await dueService.resume(
      connections: [connection],
      session: session,
      provider: { _, _, _ in await deliveries.increment() },
      reconcile: { _, _ in .notSent }
    )
    #expect(await deliveries.currentValue() == 1)
  }

  @Test
  func testScheduledSendCanBeCancelledDuringUndoWindow() async throws {
    let clock = LockedOutboxClock(Date(timeIntervalSince1970: 1_800_000_000))
    let deliveries = DeliveryCounter()
    let service = OutboxDeliveryService(now: { clock.now() }, store: InMemoryOutboxDeliveryStore())
    let dueAt = clock.now().addingTimeInterval(60)
    let attempt = try await service.enqueueScheduled(
      message,
      connection: connection,
      session: session,
      scheduleId: UUID(),
      revision: 1,
      dueAt: dueAt,
      deadline: dueAt.addingTimeInterval(24 * 60 * 60),
      undoSendDelayNanoseconds: UndoSendWindow.thirtySeconds.nanoseconds,
      provider: { _, _, _ in await deliveries.increment() },
      reconcile: { _, _ in .notSent }
    )
    #expect(attempt.canEditOrCancel == false)
    #expect(attempt.canCancel)

    clock.advance(by: 65)
    _ = try await service.cancel(attempt.id, session: session)
    clock.advance(by: 30)
    try await service.resume(
      connections: [connection],
      session: session,
      provider: { _, _, _ in await deliveries.increment() },
      reconcile: { _, _ in .notSent }
    )

    #expect(await deliveries.currentValue() == 0)
  }

  @Test
  func testScheduledSendBecomesNeedsAttentionAfterTwentyFourHoursWithoutHandoff() async throws {
    let clock = LockedOutboxClock(Date(timeIntervalSince1970: 1_800_000_000))
    let deliveries = DeliveryCounter()
    let store = InMemoryOutboxDeliveryStore()
    let dueAt = clock.now().addingTimeInterval(60)
    let queuedService = OutboxDeliveryService(now: { clock.now() }, store: store)
    _ = try await queuedService.enqueueScheduled(
      message,
      connection: connection,
      session: session,
      scheduleId: UUID(),
      revision: 1,
      dueAt: dueAt,
      deadline: dueAt.addingTimeInterval(24 * 60 * 60),
      undoSendDelayNanoseconds: 0,
      provider: { _, _, _ in Issue.record("The original process should be suspended.") },
      reconcile: { _, _ in .notSent }
    )
    await queuedService.suspend(productAccountId: session.productAccountId)
    clock.advance(by: 24 * 60 * 60 + 61)

    let restartedService = OutboxDeliveryService(now: { clock.now() }, store: store)
    try await restartedService.resume(
      connections: [connection],
      session: session,
      provider: { _, _, _ in await deliveries.increment() },
      reconcile: { _, _ in .notSent }
    )
    let retained = try #require(try await restartedService.items(session: session).first)

    #expect(retained.state == .userActionRequired)
    #expect(retained.lastErrorDescription?.contains("within 24 hours") == true)
    #expect(await deliveries.currentValue() == 0)
  }

  @Test
  func testWaitForScheduledRetriesReturnsFalseWhenIdle() async {
    let service = OutboxDeliveryService(store: InMemoryOutboxDeliveryStore())

    let waitedForRetry = await service.waitForScheduledRetries()
    #expect(!(waitedForRetry))
  }

  @Test
  func testUndoSendOffHandsMessageToProviderImmediately() async throws {
    let deliveries = DeliveryCounter()
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: 60_000_000_000,
      store: InMemoryOutboxDeliveryStore()
    )

    _ = try await service.enqueue(
      message,
      connection: connection,
      session: session,
      undoSendDelayNanoseconds: UndoSendWindow.off.nanoseconds,
      provider: { _, _, _ in await deliveries.increment() },
      reconcile: { _, _ in .notSent }
    )

    #expect(await deliveries.currentValue() == 1)
    #expect(try await service.items(session: session).isEmpty)
  }

  @Test
  func testSelectedUndoSendWindowPersistsAcrossRestart() async throws {
    let clock = LockedOutboxClock(Date(timeIntervalSince1970: 1_800_000_000))
    let deliveries = DeliveryCounter()
    let store = InMemoryOutboxDeliveryStore()
    let queuedService = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      now: { clock.now() },
      store: store
    )

    let attempt = try await queuedService.enqueue(
      message,
      connection: connection,
      session: session,
      undoSendDelayNanoseconds: UndoSendWindow.thirtySeconds.nanoseconds,
      provider: { _, _, _ in Issue.record("The queued callback must be replaced after restart.") },
      reconcile: { _, _ in .notSent }
    )
    await queuedService.suspend(productAccountId: session.productAccountId)

    #expect(
      attempt.providerHandoffNotBeforeMilliseconds
        == attempt.createdAtMilliseconds + 30_000
    )

    clock.advance(by: 20)
    let earlyResumeService = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      now: { clock.now() },
      store: store
    )
    try await earlyResumeService.resume(
      connections: [connection],
      session: session,
      provider: { _, _, _ in await deliveries.increment() },
      reconcile: { _, _ in .notSent }
    )
    #expect(await deliveries.currentValue() == 0)
    await earlyResumeService.suspend(productAccountId: session.productAccountId)

    clock.advance(by: 11)
    let dueResumeService = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      now: { clock.now() },
      store: store
    )
    try await dueResumeService.resume(
      connections: [connection],
      session: session,
      provider: { _, _, _ in await deliveries.increment() },
      reconcile: { _, _ in .notSent }
    )

    #expect(await deliveries.currentValue() == 1)
    #expect(try await dueResumeService.items(session: session).isEmpty)
  }

  @Test
  func testTransientEWSOAuthFailureIsRetryable() {
    guard
      case .transient = outboxFailureDisposition(
        for: EWSOAuthError.tokenExchangeFailed(status: 429)
      )
    else {
      Issue.record("Expected transient EWS OAuth failure")
      return
    }
  }

  @Test
  func testScheduledHandoffDoesNotCancelItsDeliveryTask() async throws {
    let cancellationRecorder = DeliveryCancellationRecorder()
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: 1_000_000,
      store: InMemoryOutboxDeliveryStore()
    )

    _ = try await service.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in
        await cancellationRecorder.record(Task.isCancelled)
      },
      reconcile: { _, _ in .notSent }
    )

    let waitedForRetry = await service.waitForScheduledRetries()
    let deliveryWasCancelled = await cancellationRecorder.wasCancelled()
    let deliveredAttempts = try await service.items(session: session)

    #expect(waitedForRetry)
    #expect(!(deliveryWasCancelled))
    #expect(deliveredAttempts.isEmpty)
  }

  @Test
  func testClearCancelsAnInFlightScheduledHandoff() async throws {
    let delivery = SuspendingDelivery()
    let store = InMemoryOutboxDeliveryStore()
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: 1_000_000,
      store: store
    )

    _ = try await service.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in
        await delivery.started()
        do {
          try await Task.sleep(nanoseconds: 60_000_000_000)
        } catch is CancellationError {
          await delivery.cancelled()
          throw CancellationError()
        }
      },
      reconcile: { _, _ in .notSent }
    )
    await delivery.waitUntilStarted()

    try await service.clear(session: session)
    await delivery.waitUntilCancelled()

    #expect(try store.load(productAccountId: session.productAccountId).isEmpty)
  }

  @Test
  func testSuspendDoesNotRescheduleAnInFlightRetry() async throws {
    let delivery = SuspendingDelivery()
    let deliveries = DeliveryCounter()
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: 1_000_000,
      retryDelayNanoseconds: { _ in 1_000_000 },
      store: InMemoryOutboxDeliveryStore()
    )

    _ = try await service.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in
        await deliveries.increment()
        await delivery.started()
        do {
          try await Task.sleep(nanoseconds: 60_000_000_000)
        } catch is CancellationError {
          await delivery.cancelled()
          throw CancellationError()
        }
      },
      reconcile: { _, _ in .notSent }
    )
    await delivery.waitUntilStarted()

    await service.suspend(productAccountId: session.productAccountId)
    await delivery.waitUntilCancelled()
    try await Task.sleep(nanoseconds: 50_000_000)
    let deliveryCount = await deliveries.currentValue()

    #expect(deliveryCount == 1)
  }

  @Test
  func testClearOnlyCancelsRetriesForItsProductAccount() async throws {
    let otherSession = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-002",
      identityToken: "product-token-002",
      productAccountId: "product-account-002",
      trustedDeviceId: "trusted-device-002"
    )
    let otherConnection = MailboxConnection(
      authorizationState: .authorized,
      capabilities: .gmail,
      connectedAt: 1_781_200_000_000,
      displayName: "other-sender@example.com",
      id: MailboxConnectionId(
        providerMailboxIdentity: StableProviderMailboxIdentity(
          providerId: .gmail,
          value: "gmail-user-002"
        )
      ),
      lastVerifiedAt: 1_781_200_000_100,
      productAccountId: ProductAccountId(otherSession.productAccountId),
      trustedDeviceId: "trusted-device-002",
      updatedAt: 1_781_200_000_200
    )
    let deliveries = DeliveryCounter()
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: 1_000_000,
      store: InMemoryOutboxDeliveryStore()
    )

    _ = try await service.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in },
      reconcile: { _, _ in .notSent }
    )
    _ = try await service.enqueue(
      message,
      connection: otherConnection,
      session: otherSession,
      provider: { _, _, _ in await deliveries.increment() },
      reconcile: { _, _ in .notSent }
    )

    try await service.clear(session: session)
    _ = await service.waitForScheduledRetries()

    let deliveryCount = await deliveries.currentValue()
    #expect(deliveryCount == 1)
  }

  @Test
  func testClearConnectionOnlyCancelsRetriesForItsProductAccount() async throws {
    let otherSession = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-002",
      identityToken: "product-token-002",
      productAccountId: "product-account-002",
      trustedDeviceId: "trusted-device-002"
    )
    let otherConnection = MailboxConnection(
      authorizationState: .authorized,
      capabilities: .gmail,
      connectedAt: 1_781_200_000_000,
      displayName: "sender@example.com",
      id: connection.id,
      lastVerifiedAt: 1_781_200_000_100,
      productAccountId: ProductAccountId(otherSession.productAccountId),
      trustedDeviceId: "trusted-device-002",
      updatedAt: 1_781_200_000_200
    )
    let deliveries = DeliveryCounter()
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: 50_000_000,
      store: InMemoryOutboxDeliveryStore()
    )

    _ = try await service.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in },
      reconcile: { _, _ in .notSent }
    )
    _ = try await service.enqueue(
      message,
      connection: otherConnection,
      session: otherSession,
      provider: { _, _, _ in await deliveries.increment() },
      reconcile: { _, _ in .notSent }
    )

    try await service.clear(connection: connection, session: session)
    _ = await service.waitForScheduledRetries()

    let deliveryCount = await deliveries.currentValue()
    #expect(deliveryCount == 1)
  }

  @Test
  func testClearCancelsAnImmediatelyResumedHandoff() async throws {
    let delivery = SuspendingDelivery()
    let store = InMemoryOutboxDeliveryStore()
    let queuedService = OutboxDeliveryService(
      handoffDelayNanoseconds: 60_000_000_000,
      store: store
    )
    _ = try await queuedService.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in },
      reconcile: { _, _ in .unknown }
    )
    await queuedService.suspend(productAccountId: session.productAccountId)
    var queuedAttempts = try store.load(productAccountId: session.productAccountId)
    queuedAttempts[0].providerHandoffNotBeforeMilliseconds = 0
    try store.save(queuedAttempts, productAccountId: session.productAccountId)
    let resumedService = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      store: store
    )
    let resumeTask = Task {
      try await resumedService.resume(
        connections: [connection],
        session: session,
        provider: { _, _, _ in
          await delivery.started()
          do {
            try await Task.sleep(nanoseconds: 60_000_000_000)
          } catch is CancellationError {
            await delivery.cancelled()
            throw CancellationError()
          }
        },
        reconcile: { _, _ in .unknown }
      )
    }
    await delivery.waitUntilStarted()

    try await resumedService.clear(session: session)
    await delivery.waitUntilCancelled()
    _ = try? await resumeTask.value

    #expect(try store.load(productAccountId: session.productAccountId).isEmpty)
  }

  @Test
  func testClearConnectionRemovesOnlyThatConnectionsQueuedAttempts() async throws {
    let store = InMemoryOutboxDeliveryStore()
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      retryDelayNanoseconds: { _ in 60_000_000_000 },
      store: store
    )

    _ = try await service.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in throw URLError(.notConnectedToInternet) },
      reconcile: { _, _ in .notSent }
    )
    try await service.clear(connection: connection, session: session)

    #expect(try store.load(productAccountId: session.productAccountId).isEmpty)
  }

  @Test
  func testSentAttemptIsPrunedAfterDelivery() async throws {
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      store: InMemoryOutboxDeliveryStore()
    )

    let sent = try await service.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in },
      reconcile: { _, _ in .notSent }
    )

    let persisted = try await service.items(session: session)
    #expect(sent.state == .sent)
    #expect(persisted.isEmpty)
  }

  @Test
  func testLoadingPrunesTerminalAttemptsPersistedByPreviousVersion() async throws {
    let store = InMemoryOutboxDeliveryStore()
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: 60_000_000_000,
      store: store
    )
    _ = try await service.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in },
      reconcile: { _, _ in .notSent }
    )
    var persisted = try store.load(productAccountId: session.productAccountId)
    persisted[0].state = .sent
    try store.save(persisted, productAccountId: session.productAccountId)

    let loaded = try await service.items(session: session)

    #expect(loaded.isEmpty)
    #expect(try store.load(productAccountId: session.productAccountId).isEmpty)
    try await service.clear(session: session)
  }

  @Test
  func testCancelledAttemptIsPruned() async throws {
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: 60_000_000_000,
      store: InMemoryOutboxDeliveryStore()
    )

    let queued = try await service.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in },
      reconcile: { _, _ in .notSent }
    )
    let cancelled = try await service.cancel(queued.id, session: session)

    let persisted = try await service.items(session: session)
    #expect(cancelled.state == .cancelled)
    #expect(persisted.isEmpty)
  }

  @Test
  func testGraphDraftIdentityPersistsAcrossRetryableFailureAndIsDeletedOnCancel() async throws {
    let cleaner = ProviderDraftCleanerRecorder()
    let store = InMemoryOutboxDeliveryStore()
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      providerDraftCleaner: { draftId, connectionId, productAccountId in
        try await cleaner.clean(
          draftId: draftId,
          connectionId: connectionId,
          productAccountId: productAccountId
        )
      },
      retryDelayNanoseconds: { _ in 60_000_000_000 },
      store: store
    )
    let retrying = try await service.enqueue(
      message,
      connection: graphConnection,
      session: session,
      provider: { _, _, _ in
        throw MicrosoftGraphSendError(
          stage: .providerHandoff,
          underlyingError: MicrosoftGraphClientError.requestFailed(429),
          providerDraftId: "graph-draft-1"
        )
      },
      reconcile: { _, _ in .notSent }
    )

    #expect(retrying.state == .retrying)
    #expect(
      try store.load(productAccountId: session.productAccountId).first?.providerDraftId
        == "graph-draft-1")

    let cancelled = try await service.cancel(retrying.id, session: session)
    let deletedDraftIds = await cleaner.deletedDraftIds()

    #expect(cancelled.state == .cancelled)
    #expect(deletedDraftIds == ["graph-draft-1"])
    #expect(try store.load(productAccountId: session.productAccountId).isEmpty)
  }

  @Test
  func testGraphDraftIdentityPersistenceFailurePreservesDeliveryDisposition() async throws {
    let store = FailingOutboxDeliveryStore(failingSaveNumber: 3)
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      retryDelayNanoseconds: { _ in 60_000_000_000 },
      store: store
    )

    let retrying = try await service.enqueue(
      message,
      connection: graphConnection,
      session: session,
      provider: { _, _, _ in
        throw MicrosoftGraphSendError(
          stage: .providerHandoff,
          underlyingError: MicrosoftGraphClientError.requestFailed(429),
          providerDraftId: "unpersisted-draft"
        )
      },
      reconcile: { _, _ in .notSent }
    )

    #expect(retrying.state == .retrying)
    #expect(
      try store.load(productAccountId: session.productAccountId).first?.providerDraftId == nil)
  }

  @Test
  func testGraphDraftCleanupFailureRetriesWithoutChangingCancelledOutcome() async throws {
    let cleaner = ProviderDraftCleanerRecorder(failureCount: 1, suspendedAttempt: 2)
    let store = InMemoryOutboxDeliveryStore()
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      providerDraftCleaner: { draftId, connectionId, productAccountId in
        try await cleaner.clean(
          draftId: draftId,
          connectionId: connectionId,
          productAccountId: productAccountId
        )
      },
      retryDelayNanoseconds: { _ in 1_000_000 },
      store: store
    )
    let retrying = try await service.enqueue(
      message,
      connection: graphConnection,
      session: session,
      provider: { _, _, _ in
        throw MicrosoftGraphSendError(
          stage: .providerHandoff,
          underlyingError: MicrosoftGraphClientError.requestFailed(429),
          providerDraftId: "graph-draft-2"
        )
      },
      reconcile: { _, _ in .notSent }
    )

    let cancelled = try await service.cancel(retrying.id, session: session)
    let retained = try requireValue(
      try store.load(productAccountId: session.productAccountId).first)
    #expect(cancelled.state == .cancelled)
    #expect(retained.state == .cancelled)
    #expect(retained.providerDraftId == "graph-draft-2")
    #expect(retained.providerDraftCleanupErrorDescription != nil)

    await cleaner.waitUntilSuspended()
    await cleaner.resumeSuspendedAttempt()
    let waitedForCleanup = await service.waitForScheduledRetries()
    let cleanupAttemptCount = await cleaner.attemptCount()

    #expect(waitedForCleanup)
    #expect(cleanupAttemptCount == 2)
    #expect(try store.load(productAccountId: session.productAccountId).isEmpty)
  }

  @Test
  func testAccountClearRetainsOnlyDraftCleanupFailures() async throws {
    let cleaner = ProviderDraftCleanerRecorder(failureCount: 1)
    let store = InMemoryOutboxDeliveryStore()
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      providerDraftCleaner: { draftId, connectionId, productAccountId in
        try await cleaner.clean(
          draftId: draftId,
          connectionId: connectionId,
          productAccountId: productAccountId
        )
      },
      retryDelayNanoseconds: { _ in 60_000_000_000 },
      store: store
    )
    _ = try await service.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in throw URLError(.notConnectedToInternet) },
      reconcile: { _, _ in .notSent }
    )
    _ = try await enqueueRetainedGraphDraft("retained-draft", service: service)

    do {
      try await service.clear(session: session)
      Issue.record("Expected provider draft cleanup to fail")
    } catch TestOutboxError.deliveryRejected {}

    let retainedAttempts = try store.load(productAccountId: session.productAccountId)
    let waitedForCleanup = await service.waitForScheduledRetries()
    #expect(retainedAttempts.map(\.providerDraftId) == ["retained-draft"])
    #expect(!(waitedForCleanup))
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testConnectionClearRetainsOnlyItsDraftCleanupFailures() async throws {
    let cleaner = ProviderDraftCleanerRecorder(failureCount: 10)
    let deliveries = DeliveryCounter()
    let store = InMemoryOutboxDeliveryStore()
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      maximumAttempts: 2,
      providerDraftCleaner: { draftId, connectionId, productAccountId in
        try await cleaner.clean(
          draftId: draftId,
          connectionId: connectionId,
          productAccountId: productAccountId
        )
      },
      retryDelayNanoseconds: { _ in 100_000_000 },
      store: store
    )
    let retainedDraft = try await service.enqueue(
      message,
      connection: graphConnection,
      session: session,
      provider: { _, _, _ in
        await deliveries.increment()
        throw MicrosoftGraphSendError(
          stage: .providerHandoff,
          underlyingError: MicrosoftGraphClientError.requestFailed(429),
          providerDraftId: "connection-draft"
        )
      },
      reconcile: { _, _ in .notSent }
    )
    _ = try await service.enqueue(
      message,
      connection: graphConnection,
      session: session,
      provider: { _, _, _ in throw URLError(.notConnectedToInternet) },
      reconcile: { _, _ in .notSent }
    )
    let unrelatedAttempt = try await service.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in throw URLError(.notConnectedToInternet) },
      reconcile: { _, _ in .notSent }
    )

    do {
      try await service.clear(connection: graphConnection, session: session)
      Issue.record("Expected provider draft cleanup to fail")
    } catch TestOutboxError.deliveryRejected {}

    let retainedAttempts = try store.load(productAccountId: session.productAccountId)
    #expect(Set(retainedAttempts.map(\.id)) == Set([retainedDraft.id, unrelatedAttempt.id]))
    let waitedForCleanup = await service.waitForScheduledRetries()
    let deliveryCount = await deliveries.currentValue()
    #expect(waitedForCleanup)
    #expect(deliveryCount == 1)
    await service.suspend(productAccountId: session.productAccountId)
  }

  @Test
  func testResumeDeletesPersistedProviderDraftAfterRestart() async throws {
    let store = InMemoryOutboxDeliveryStore()
    let originalService = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      retryDelayNanoseconds: { _ in 60_000_000_000 },
      store: store
    )
    let retained = try await enqueueRetainedGraphDraft(
      "restart-draft",
      service: originalService
    )
    await originalService.suspend(productAccountId: session.productAccountId)
    var attempts = try store.load(productAccountId: session.productAccountId)
    attempts[0].state = .cancelled
    try store.save(attempts, productAccountId: session.productAccountId)
    let cleaner = ProviderDraftCleanerRecorder()
    let restartedService = OutboxDeliveryService(
      providerDraftCleaner: { draftId, connectionId, productAccountId in
        try await cleaner.clean(
          draftId: draftId,
          connectionId: connectionId,
          productAccountId: productAccountId
        )
      },
      retryDelayNanoseconds: { _ in 0 },
      store: store
    )

    try await restartedService.resume(
      connections: [graphConnection],
      session: session,
      provider: { _, _, _ in },
      reconcile: { _, _ in .notSent }
    )
    _ = await restartedService.waitForScheduledRetries()
    let deletedDraftIds = await cleaner.deletedDraftIds()

    #expect(deletedDraftIds == ["restart-draft"])
    #expect(
      !(try store.load(productAccountId: session.productAccountId).contains {
        $0.id == retained.id
      }))
  }

  @Test
  func testPermanentGraphFailureDeletesProviderDraftWithoutChangingFailureOutcome() async throws {
    let cleaner = ProviderDraftCleanerRecorder()
    let store = InMemoryOutboxDeliveryStore()
    let service = graphDraftService(cleaner: cleaner, store: store)

    let failed = try await service.enqueue(
      message,
      connection: graphConnection,
      session: session,
      provider: { _, _, _ in
        throw MicrosoftGraphSendError(
          stage: .providerHandoff,
          underlyingError: MicrosoftGraphClientError.requestFailed(400),
          providerDraftId: "abandoned-draft"
        )
      },
      reconcile: { _, _ in .notSent }
    )

    let persisted = try requireValue(
      try store.load(productAccountId: session.productAccountId).first)
    let deletedDraftIds = await cleaner.deletedDraftIds()
    #expect(failed.state == .failed)
    #expect(persisted.state == .failed)
    #expect(persisted.providerDraftId == nil)
    #expect(deletedDraftIds == ["abandoned-draft"])
  }

  @Test
  func testEditingGraphAttemptDeletesOldProviderDraftBeforeReplacement() async throws {
    let cleaner = ProviderDraftCleanerRecorder()
    let store = InMemoryOutboxDeliveryStore()
    let service = graphDraftService(cleaner: cleaner, store: store)
    let retrying = try await enqueueRetainedGraphDraft(
      "edited-draft",
      service: service
    )

    let replacement = try await service.edit(
      retrying.id,
      message: OutgoingMessage(
        body: "Edited body",
        recipient: message.recipient,
        subject: message.subject
      ),
      connection: graphConnection,
      session: session,
      provider: { _, _, _ in throw URLError(.notConnectedToInternet) },
      reconcile: { _, _ in .notSent }
    )

    let deletedDraftIds = await cleaner.deletedDraftIds()
    #expect(replacement.state == .pending)
    #expect(deletedDraftIds == ["edited-draft"])
    #expect(
      !(try store.load(productAccountId: session.productAccountId).contains {
        $0.id == retrying.id
      }))
  }

  @Test
  func testConnectionRemovalDeletesRetainedGraphDraftBeforeClearingAttempt() async throws {
    let cleaner = ProviderDraftCleanerRecorder()
    let store = InMemoryOutboxDeliveryStore()
    let service = graphDraftService(cleaner: cleaner, store: store)
    _ = try await enqueueRetainedGraphDraft("removed-connection-draft", service: service)

    try await service.clear(connection: graphConnection, session: session)

    let deletedDraftIds = await cleaner.deletedDraftIds()
    #expect(deletedDraftIds == ["removed-connection-draft"])
    #expect(try store.load(productAccountId: session.productAccountId).isEmpty)
  }

  @Test
  func testSignOutDeletesRetainedGraphDraftBeforeClearingOutbox() async throws {
    let cleaner = ProviderDraftCleanerRecorder()
    let store = InMemoryOutboxDeliveryStore()
    let service = graphDraftService(cleaner: cleaner, store: store)
    _ = try await enqueueRetainedGraphDraft("signed-out-draft", service: service)

    try await service.clear(session: session)

    let deletedDraftIds = await cleaner.deletedDraftIds()
    #expect(deletedDraftIds == ["signed-out-draft"])
    #expect(try store.load(productAccountId: session.productAccountId).isEmpty)
  }

  @Test
  func testScheduledHandoffRetriesWhenPersistingItsClaimFails() async throws {
    let store = FailingOutboxDeliveryStore(failingSaveNumber: 2)
    let deliveries = DeliveryCounter()
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: 1_000_000,
      retryDelayNanoseconds: { _ in 1_000_000 },
      store: store
    )

    _ = try await service.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in await deliveries.increment() },
      reconcile: { _, _ in .notSent }
    )
    let waitedForRetry = await service.waitForScheduledRetries()
    let deliveryCount = await deliveries.currentValue()
    let attempts = try await service.items(session: session)

    #expect(waitedForRetry)
    #expect(deliveryCount == 1)
    #expect(attempts.isEmpty)
  }

  @Test
  func testExhaustedHandoffClaimFailuresStopRetrying() async throws {
    let store = FailingOutboxDeliveryStore(failingSaveNumber: 2)
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: 1_000_000,
      maximumAttempts: 1,
      retryDelayNanoseconds: { _ in 1_000_000 },
      store: store
    )
    _ = try await service.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in Issue.record("The failed claim must not deliver.") },
      reconcile: { _, _ in .notSent }
    )

    let completed = expectation(description: "retry queue drains")
    Task {
      if await service.waitForScheduledRetries() {
        completed.fulfill()
      }
    }
    await fulfillment(of: [completed], timeout: 1)
    let attempts = try await service.items(session: session)
    #expect(attempts.first?.state == .pending)
  }

  @Test
  func testResumeReplacesSleepingRetryWithCurrentCallbacks() async throws {
    let originalDeliveries = DeliveryCounter()
    let refreshedDeliveries = DeliveryCounter()
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: 50_000_000,
      store: InMemoryOutboxDeliveryStore()
    )
    _ = try await service.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in await originalDeliveries.increment() },
      reconcile: { _, _ in .notSent }
    )

    try await service.resume(
      connections: [connection],
      session: session,
      provider: { _, _, _ in await refreshedDeliveries.increment() },
      reconcile: { _, _ in .notSent }
    )
    _ = await service.waitForScheduledRetries()

    let originalDeliveryCount = await originalDeliveries.currentValue()
    let refreshedDeliveryCount = await refreshedDeliveries.currentValue()
    #expect(originalDeliveryCount == 0)
    #expect(refreshedDeliveryCount == 1)
  }

  @Test
  func testResumePreservesRetryScheduledWhileProcessingConnection() async throws {
    let store = InMemoryOutboxDeliveryStore()
    let seedService = OutboxDeliveryService(
      handoffDelayNanoseconds: 60_000_000_000,
      store: store
    )
    _ = try await seedService.enqueue(
      OutgoingMessage(body: "First", recipient: message.recipient, subject: "First"),
      connection: connection,
      session: session,
      provider: { _, _, _ in },
      reconcile: { _, _ in .notSent }
    )
    _ = try await seedService.enqueue(
      OutgoingMessage(body: "Second", recipient: message.recipient, subject: "Second"),
      connection: connection,
      session: session,
      provider: { _, _, _ in },
      reconcile: { _, _ in .notSent }
    )
    await seedService.suspend(productAccountId: session.productAccountId)
    var seededAttempts = try store.load(productAccountId: session.productAccountId)
    for index in seededAttempts.indices {
      seededAttempts[index].providerHandoffNotBeforeMilliseconds = 0
    }
    try store.save(seededAttempts, productAccountId: session.productAccountId)
    let delivery = TransientSecondMessageDelivery()
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      retryDelayNanoseconds: { _ in 100_000_000 },
      store: store
    )

    try await service.resume(
      connections: [connection],
      session: session,
      provider: { message, _, _ in try await delivery.deliver(message) },
      reconcile: { _, _ in .notSent }
    )
    _ = await service.waitForScheduledRetries()

    let attempts = try await service.items(session: session)
    let secondMessageAttemptCount = await delivery.attemptCount()
    #expect(attempts.isEmpty)
    #expect(secondMessageAttemptCount == 2)
  }

  @Test
  func testResumeReturnsAfterSchedulingFutureRetry() async throws {
    let store = InMemoryOutboxDeliveryStore()
    let seedService = OutboxDeliveryService(
      handoffDelayNanoseconds: 60_000_000_000,
      store: store
    )
    _ = try await seedService.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in },
      reconcile: { _, _ in .notSent }
    )
    var attempts = try store.load(productAccountId: session.productAccountId)
    attempts[0].state = .retrying
    attempts[0].nextRetryAtMilliseconds = Int64(Date().timeIntervalSince1970 * 1_000) + 60_000
    try store.save(attempts, productAccountId: session.productAccountId)

    let service = OutboxDeliveryService(store: store)
    let completed = expectation(description: "resume returns after scheduling")
    Task {
      try? await service.resume(
        connections: [connection],
        session: session,
        provider: { _, _, _ in },
        reconcile: { _, _ in .notSent }
      )
      completed.fulfill()
    }

    await fulfillment(of: [completed], timeout: 1)
    try await service.clear(session: session)
  }

  @Test
  func testPreRequestHostFailurePersistsAndResumesAfterRestart() async throws {
    let store = InMemoryOutboxDeliveryStore()
    let clock = LockedOutboxClock(Date(timeIntervalSince1970: 1_781_200_000))
    let firstService = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      now: { clock.now() },
      retryDelayNanoseconds: { _ in 60_000_000_000 },
      store: store
    )

    _ = try await firstService.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in throw URLError(.cannotFindHost) },
      reconcile: { _, _ in .notSent }
    )

    let queued = try await firstService.items(session: session)
    #expect(queued.count == 1)
    #expect(queued.first?.state == .retrying)

    clock.advance(by: 61)
    let restartedService = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      now: { clock.now() },
      retryDelayNanoseconds: { _ in 0 },
      store: store
    )
    let deliveredIds = DeliveryIdRecorder()
    try await restartedService.resume(
      connections: [connection],
      session: session,
      provider: { _, idempotencyKey, _ in await deliveredIds.append(idempotencyKey) },
      reconcile: { _, _ in .notSent }
    )

    let resumed = try await restartedService.items(session: session)
    let recordedIds = await deliveredIds.values
    #expect(recordedIds == [queued[0].idempotencyKey])
    #expect(resumed.isEmpty)
  }

  @Test
  func testGmailRateLimitFailureRetriesWithoutReconciliation() async throws {
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      retryDelayNanoseconds: { _ in 60_000_000_000 },
      store: InMemoryOutboxDeliveryStore()
    )

    _ = try await service.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in throw GmailProviderMailActionError.rateLimitedResponseStatus(403) },
      reconcile: { _, _ in .unknown }
    )

    let attempts = try await service.items(session: session)
    #expect(attempts.first?.state == .retrying)
  }

  @Test
  func testGmailHTTP429FailureRetriesWithoutReconciliation() async throws {
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      retryDelayNanoseconds: { _ in 60_000_000_000 },
      store: InMemoryOutboxDeliveryStore()
    )

    _ = try await service.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in throw GmailProviderMailActionError.responseStatus(429) },
      reconcile: { _, _ in .unknown }
    )

    let attempts = try await service.items(session: session)
    #expect(attempts.first?.state == .retrying)
  }

  @Test
  func testEWSAuthenticationFailureRequiresUserAction() async throws {
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      store: InMemoryOutboxDeliveryStore()
    )

    _ = try await service.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in throw EWSServiceError.authenticationRejected },
      reconcile: { _, _ in .unknown }
    )

    let attempts = try await service.items(session: session)
    #expect(attempts.first?.state == .userActionRequired)
  }

  @Test
  func testEWSHTTP5xxFailureReconcilesBeforeRetrying() async throws {
    let reconciliations = DeliveryCounter()
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      store: InMemoryOutboxDeliveryStore()
    )

    _ = try await service.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in
        throw EWSServiceError.response(code: "HTTP 503", message: "Unavailable")
      },
      reconcile: { _, _ in
        await reconciliations.increment()
        return .unknown
      }
    )

    let attempts = try await service.items(session: session)
    let reconciliationCount = await reconciliations.currentValue()
    #expect(reconciliationCount == 1)
    #expect(attempts.first?.state == .outcomeUnknown)
  }

  @Test
  func testEWSTransientServerResponsesRetryWithoutReconciliation() async throws {
    for code in [
      "ErrorADUnavailable",
      "ErrorInternalServerTransientError",
      "ErrorServerBusy",
    ] {
      let reconciliations = DeliveryCounter()
      let service = OutboxDeliveryService(
        handoffDelayNanoseconds: immediateHandoffDelay,
        retryDelayNanoseconds: { _ in 60_000_000_000 },
        store: InMemoryOutboxDeliveryStore()
      )

      _ = try await service.enqueue(
        message,
        connection: connection,
        session: session,
        provider: { _, _, _ in
          throw EWSServiceError.response(code: code, message: "Temporarily unavailable")
        },
        reconcile: { _, _ in
          await reconciliations.increment()
          return .unknown
        }
      )

      let attempts = try await service.items(session: session)
      let reconciliationCount = await reconciliations.currentValue()
      #expect(reconciliationCount == 0, Comment(rawValue: code))
      #expect(attempts.first?.state == .retrying, Comment(rawValue: code))
      try await service.clear(session: session)
    }
  }

  @Test
  func testEWSAmbiguousResponsesAlwaysReconcileBeforeRetrying() async throws {
    let errors: [EWSServiceError] = [
      .response(code: "HTTP 408", message: "Timeout"),
      .response(code: "HTTP 425", message: "Too Early"),
      .invalidResponse,
    ]

    for error in errors {
      let reconciliations = DeliveryCounter()
      let service = OutboxDeliveryService(
        handoffDelayNanoseconds: immediateHandoffDelay,
        store: InMemoryOutboxDeliveryStore()
      )
      _ = try await service.enqueue(
        message,
        connection: connection,
        session: session,
        provider: { _, _, _ in throw error },
        reconcile: { _, _ in
          await reconciliations.increment()
          return .unknown
        }
      )

      let attempts = try await service.items(session: session)
      let reconciliationCount = await reconciliations.currentValue()
      #expect(reconciliationCount == 1)
      #expect(attempts.first?.state == .outcomeUnknown)
    }
  }

  @Test
  func testAmbiguousFailureReconcilesSentWithoutDuplicateDelivery() async throws {
    let store = InMemoryOutboxDeliveryStore()
    let deliveries = DeliveryCounter()
    let service = OutboxDeliveryService(
      failureDisposition: { _ in .ambiguous },
      handoffDelayNanoseconds: immediateHandoffDelay,
      store: store
    )

    _ = try await service.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in
        await deliveries.increment()
        throw URLError(.timedOut)
      },
      reconcile: { _, _ in .sent }
    )
    try await service.resume(
      connections: [connection],
      session: session,
      provider: { _, _, _ in await deliveries.increment() },
      reconcile: { _, _ in .notSent }
    )

    let deliveryCount = await deliveries.value
    let attempts = try await service.items(session: session)
    #expect(deliveryCount == 1)
    #expect(attempts.isEmpty)
  }

  @Test
  func testDeliveredMessageKeepsSentCopyPendingVisibleWithoutResubmission() async throws {
    let clock = LockedOutboxClock(Date(timeIntervalSince1970: 1_800_000_000))
    let store = InMemoryOutboxDeliveryStore()
    let deliveries = DeliveryCounter()
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      now: { clock.now() },
      retryDelayNanoseconds: { _ in 60_000_000_000 },
      store: store
    )

    let pending = try await service.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in
        await deliveries.increment()
        throw StandardsMailDeliveryError.sentCopyPending
      },
      reconcile: { _, _ in
        Issue.record("The delayed reconciliation must not run yet.")
        return .sentCopyPending
      }
    )

    #expect(pending.state == .sentCopyPending)
    #expect(
      pending.lastErrorDescription == "Message delivered. Saving its copy to the Sent mailbox.")
    #expect(await deliveries.currentValue() == 1)
    await service.suspend(productAccountId: session.productAccountId)
    clock.advance(by: 61)

    let restartedService = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      now: { clock.now() },
      retryDelayNanoseconds: { _ in 0 },
      store: store
    )
    try await restartedService.resume(
      connections: [connection],
      session: session,
      provider: { _, _, _ in Issue.record("Sent-copy recovery must not resubmit SMTP.") },
      reconcile: { _, _ in .sent }
    )

    #expect(await deliveries.currentValue() == 1)
    #expect(try await restartedService.items(session: session).isEmpty)
  }

  @Test(
    "Permanently failing Sent append stops at its attempt or age bound",
    .bug("https://github.com/unwired-dev/product/issues/442"),
    arguments: [
      (2, TimeInterval(7 * 24 * 60 * 60), 1),
      (10, TimeInterval(60), 0),
    ]
  )
  // swiftlint:disable:next function_body_length
  func testPermanentlyFailingSentAppendStopsAndClearsJournal(
    maximumAttempts: Int,
    maximumAge: TimeInterval,
    expectedReconciliationCount: Int
  ) async throws {
    let clock = LockedOutboxClock(Date(timeIntervalSince1970: 1_800_000_000))
    let outboxStore = InMemoryOutboxDeliveryStore()
    let sentCopyStore = InMemoryStandardsMailSentCopyStore()
    let deliveries = DeliveryCounter()
    let reconciliations = DeliveryCounter()
    let unrelatedCopy = StandardsMailPendingSentCopy(
      connectionId: connection.id,
      idempotencyKey: "unrelated-copy",
      mailbox: "Sent",
      rawMessage: Data("Message-ID: <unrelated-copy@example.com>\r\n\r\nBody".utf8),
      rfcMessageId: "<unrelated-copy@example.com>"
    )
    try sentCopyStore.save(
      [unrelatedCopy],
      productAccountId: session.productAccountId,
      connectionId: connection.id
    )
    let seedService = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      maximumAge: maximumAge,
      maximumAttempts: maximumAttempts,
      now: { clock.now() },
      retryDelayNanoseconds: { _ in 60_000_000_000 },
      sentCopyStore: sentCopyStore,
      store: outboxStore
    )
    let pendingAttempt = try await seedService.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, idempotencyKey, _ in
        var copies = try sentCopyStore.load(
          productAccountId: self.session.productAccountId,
          connectionId: self.connection.id
        )
        copies.append(
          StandardsMailPendingSentCopy(
            connectionId: self.connection.id,
            idempotencyKey: idempotencyKey,
            mailbox: "Sent",
            rawMessage: Data("Message-ID: <pending-copy@example.com>\r\n\r\nBody".utf8),
            rfcMessageId: "<pending-copy@example.com>"
          ))
        try sentCopyStore.save(
          copies,
          productAccountId: self.session.productAccountId,
          connectionId: self.connection.id
        )
        await deliveries.increment()
        throw StandardsMailDeliveryError.sentCopyPending
      },
      reconcile: { _, _ in .sentCopyPending }
    )
    #expect(pendingAttempt.state == .sentCopyPending)
    await seedService.suspend(productAccountId: session.productAccountId)
    clock.advance(by: 61)

    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      maximumAge: maximumAge,
      maximumAttempts: maximumAttempts,
      now: { clock.now() },
      retryDelayNanoseconds: { _ in 60_000_000_000 },
      sentCopyStore: sentCopyStore,
      store: outboxStore
    )
    try await service.resume(
      connections: [connection],
      session: session,
      provider: { _, _, _ in Issue.record("Sent-copy recovery must not resubmit SMTP.") },
      reconcile: { _, _ in
        await reconciliations.increment()
        return .sentCopyPending
      }
    )

    #expect(await deliveries.currentValue() == 1)
    #expect(await reconciliations.currentValue() == expectedReconciliationCount)
    #expect(try await service.items(session: session).isEmpty)
    #expect(
      try sentCopyStore.load(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      ) == [unrelatedCopy]
    )
    await service.suspend(productAccountId: session.productAccountId)
  }

  @Test("Sent-copy cleanup resumes after the terminal state write fails")
  // swiftlint:disable:next function_body_length
  func testSentCopyCleanupResumesAfterTerminalStateWriteFailure() async throws {
    let outboxStore = FailingOutboxDeliveryStore(failingSaveNumber: 4)
    let sentCopyStore = InMemoryStandardsMailSentCopyStore()
    let deliveries = DeliveryCounter()
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      maximumAttempts: 1,
      retryDelayNanoseconds: { _ in 60_000_000_000 },
      sentCopyStore: sentCopyStore,
      store: outboxStore
    )

    do {
      _ = try await service.enqueue(
        message,
        connection: connection,
        session: session,
        provider: { _, idempotencyKey, _ in
          try sentCopyStore.save(
            [
              StandardsMailPendingSentCopy(
                connectionId: self.connection.id,
                idempotencyKey: idempotencyKey,
                mailbox: "Sent",
                rawMessage: Data("Message-ID: <pending-copy@example.com>\r\n\r\nBody".utf8),
                rfcMessageId: "<pending-copy@example.com>"
              )
            ],
            productAccountId: self.session.productAccountId,
            connectionId: self.connection.id
          )
          await deliveries.increment()
          throw StandardsMailDeliveryError.sentCopyPending
        },
        reconcile: { _, _ in .sentCopyPending }
      )
      Issue.record("Expected the terminal state write to fail")
    } catch TestOutboxError.persistenceFailed {
      // The durable repair limit must survive after journal cleanup succeeds.
    } catch {
      Issue.record("Expected persistence failure, got \(error)")
    }

    #expect(await deliveries.currentValue() == 1)
    #expect(
      try sentCopyStore.load(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      ).isEmpty)
    let pendingAttempt = try #require(
      try outboxStore.load(productAccountId: session.productAccountId).first)
    #expect(pendingAttempt.state == .sentCopyPending)
    #expect(pendingAttempt.reconciliationAttemptCount == 1)
    await service.suspend(productAccountId: session.productAccountId)

    let restartedService = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      maximumAttempts: 1,
      retryDelayNanoseconds: { _ in 0 },
      sentCopyStore: sentCopyStore,
      store: outboxStore
    )
    try await restartedService.resume(
      connections: [connection],
      session: session,
      provider: { _, _, _ in Issue.record("Sent-copy cleanup must not resubmit SMTP.") },
      reconcile: { _, _ in
        Issue.record("Exhausted Sent-copy cleanup must not reconcile again.")
        return .sentCopyPending
      }
    )

    #expect(await deliveries.currentValue() == 1)
    #expect(try await restartedService.items(session: session).isEmpty)
  }

  @Test
  func testSentCopyAuthorizationFailureRequiresUserAction() async throws {
    let clock = LockedOutboxClock(Date(timeIntervalSince1970: 1_800_000_000))
    let store = InMemoryOutboxDeliveryStore()
    let seedService = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      now: { clock.now() },
      retryDelayNanoseconds: { _ in 60_000_000_000 },
      store: store
    )
    _ = try await seedService.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in throw StandardsMailDeliveryError.sentCopyPending },
      reconcile: { _, _ in .sentCopyPending }
    )
    await seedService.suspend(productAccountId: session.productAccountId)
    clock.advance(by: 61)

    let service = OutboxDeliveryService(
      failureDisposition: { _ in .userActionRequired },
      handoffDelayNanoseconds: immediateHandoffDelay,
      now: { clock.now() },
      store: store
    )
    try await service.resume(
      connections: [connection],
      session: session,
      provider: { _, _, _ in Issue.record("Sent-copy recovery must not resubmit.") },
      reconcile: { _, _ in throw TestOutboxError.deliveryRejected }
    )

    let attempts = try await service.items(session: session)
    #expect(attempts.first?.state == .userActionRequired)
    #expect(attempts.first?.nextRetryAtMilliseconds == nil)
    #expect(attempts.first?.reconciliationPausedForAuthorization == true)
  }

  @Test
  func testEditingPrunesSupersededAttemptAndKeepsActiveReplacement() async throws {
    let store = InMemoryOutboxDeliveryStore()
    let failedService = OutboxDeliveryService(
      failureDisposition: { _ in .permanent },
      handoffDelayNanoseconds: immediateHandoffDelay,
      store: store
    )
    let failed = try await failedService.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in throw TestOutboxError.deliveryRejected },
      reconcile: { _, _ in .notSent }
    )

    #expect(failed.state == .failed)
    let replacementService = OutboxDeliveryService(
      handoffDelayNanoseconds: 60_000_000_000,
      store: store
    )
    let replacement = try await replacementService.edit(
      failed.id,
      message: OutgoingMessage(
        body: "Corrected body",
        recipient: message.recipient,
        subject: message.subject
      ),
      connection: connection,
      session: session,
      provider: { _, _, _ in },
      reconcile: { _, _ in .notSent }
    )

    let attempts = try await replacementService.items(session: session)
    #expect(attempts.map(\.id) == [replacement.id])
    #expect(attempts.first?.state == .pending)
    #expect(failed.id != replacement.id)
    #expect(failed.idempotencyKey != replacement.idempotencyKey)
    #expect(replacement.message.body == "Corrected body")
    try await replacementService.clear(session: session)
  }

  @Test
  func testEditKeepsOriginalScheduledHandoffWhenReplacementCannotBePersisted() async throws {
    let store = FailingOutboxDeliveryStore(failingSaveNumber: 2)
    let deliveries = DeliveryCounter()
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: 1_000_000,
      store: store
    )

    let queued = try await service.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in await deliveries.increment() },
      reconcile: { _, _ in .notSent }
    )

    do {
      _ = try await service.edit(
        queued.id,
        message: OutgoingMessage(
          body: "Corrected body",
          recipient: self.message.recipient,
          subject: self.message.subject
        ),
        connection: self.connection,
        session: self.session,
        provider: { _, _, _ in await deliveries.increment() },
        reconcile: { _, _ in .notSent }
      )
      Issue.record("Expected replacement persistence to fail")
    } catch TestOutboxError.persistenceFailed {
      // The original scheduled handoff must remain active after this failure.
    } catch {
      Issue.record("Expected persistence failure, got \(error)")
    }

    let waitedForRetry = await service.waitForScheduledRetries()
    let deliveryCount = await deliveries.currentValue()
    let attempts = try await service.items(session: session)

    #expect(waitedForRetry)
    #expect(deliveryCount == 1)
    #expect(attempts.isEmpty)
  }

  @Test
  func testRetryLimitStopsTransientDelivery() async throws {
    let store = InMemoryOutboxDeliveryStore()
    let clock = LockedOutboxClock(Date(timeIntervalSince1970: 1_781_200_000))
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      maximumAttempts: 2,
      now: { clock.now() },
      retryDelayNanoseconds: { _ in 60_000_000_000 },
      store: store
    )
    _ = try await service.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in throw URLError(.notConnectedToInternet) },
      reconcile: { _, _ in .notSent }
    )

    clock.advance(by: 61)
    try await service.resume(
      connections: [connection],
      session: session,
      provider: { _, _, _ in throw URLError(.notConnectedToInternet) },
      reconcile: { _, _ in .notSent }
    )

    let attempts = try await service.items(session: session)
    let attempt = try requireValue(attempts.first)
    #expect(attempt.attemptCount == 2)
    #expect(attempt.state == .failed)
    #expect(attempt.nextRetryAtMilliseconds == nil)
  }

  @Test
  func testRestartReconcilesInterruptedHandoffWithoutResending() async throws {
    let store = InMemoryOutboxDeliveryStore()
    let firstService = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      retryDelayNanoseconds: { _ in 60_000_000_000 },
      store: store
    )
    _ = try await firstService.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in throw URLError(.notConnectedToInternet) },
      reconcile: { _, _ in .notSent }
    )
    var persisted = try store.load(productAccountId: session.productAccountId)
    persisted[0].state = .handingOff
    try store.save(persisted, productAccountId: session.productAccountId)
    let deliveries = DeliveryCounter()
    let restartedService = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      store: store
    )

    try await restartedService.resume(
      connections: [connection],
      session: session,
      provider: { _, _, _ in await deliveries.increment() },
      reconcile: { _, _ in .sent }
    )

    let deliveryCount = await deliveries.currentValue()
    #expect(deliveryCount == 0)
    let attempts = try await restartedService.items(session: session)
    #expect(attempts.isEmpty)
  }

  @Test
  func testRestartReconcilesProviderSuccessWhenPersistingSentStateFails() async throws {
    let store = FailingOutboxDeliveryStore(failingSaveNumber: 3)
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      store: store
    )

    do {
      _ = try await service.enqueue(
        message,
        connection: connection,
        session: session,
        provider: { _, _, _ in },
        reconcile: { _, _ in .notSent }
      )
      Issue.record("Persisting successful delivery should fail.")
    } catch TestOutboxError.persistenceFailed {}

    let deliveries = DeliveryCounter()
    let restartedService = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      store: store
    )
    try await restartedService.resume(
      connections: [connection],
      session: session,
      provider: { _, _, _ in await deliveries.increment() },
      reconcile: { _, _ in .sent }
    )

    let deliveryCount = await deliveries.currentValue()
    let attempts = try await restartedService.items(session: session)
    #expect(deliveryCount == 0)
    #expect(attempts.isEmpty)
  }

  @Test
  func testWaitingForScheduledRetryCompletesAfterDeliveryStateIsStored() async throws {
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: 1_000_000,
      store: InMemoryOutboxDeliveryStore()
    )

    _ = try await service.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in },
      reconcile: { _, _ in .notSent }
    )
    let waited = await service.waitForScheduledRetries()

    let attempts = try await service.items(session: session)
    #expect(waited)
    #expect(attempts.isEmpty)
  }

  @Test
  func testTemporaryReconciliationFailureRetriesConfirmationWithoutResending() async throws {
    let store = InMemoryOutboxDeliveryStore()
    let clock = LockedOutboxClock(Date(timeIntervalSince1970: 1_781_200_000))
    let seedService = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      now: { clock.now() },
      retryDelayNanoseconds: { _ in 60_000_000_000 },
      store: store
    )
    _ = try await seedService.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in throw URLError(.notConnectedToInternet) },
      reconcile: { _, _ in .notSent }
    )
    var persisted = try store.load(productAccountId: session.productAccountId)
    persisted[0].state = .handingOff
    try store.save(persisted, productAccountId: session.productAccountId)
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      now: { clock.now() },
      retryDelayNanoseconds: { _ in 60_000_000_000 },
      store: store
    )
    let deliveries = DeliveryCounter()
    try await service.resume(
      connections: [connection],
      session: session,
      provider: { _, _, _ in await deliveries.increment() },
      reconcile: { _, _ in throw URLError(.notConnectedToInternet) }
    )
    let reconcilingAttempts = try await service.items(session: session)
    #expect(reconcilingAttempts.first?.state == .reconciling)

    clock.advance(by: 61)
    try await service.resume(
      connections: [connection],
      session: session,
      provider: { _, _, _ in await deliveries.increment() },
      reconcile: { _, _ in .sent }
    )

    let deliveryCount = await deliveries.currentValue()
    #expect(deliveryCount == 0)
    let sentAttempts = try await service.items(session: session)
    #expect(sentAttempts.isEmpty)
  }

  @Test
  func testReconciliationAuthorizationFailureRequiresUserAction() async throws {
    let store = InMemoryOutboxDeliveryStore()
    let seedService = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      store: store
    )
    _ = try await seedService.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in throw URLError(.notConnectedToInternet) },
      reconcile: { _, _ in .notSent }
    )
    var persisted = try store.load(productAccountId: session.productAccountId)
    persisted[0].state = .handingOff
    try store.save(persisted, productAccountId: session.productAccountId)

    let service = OutboxDeliveryService(
      failureDisposition: { _ in .userActionRequired },
      handoffDelayNanoseconds: immediateHandoffDelay,
      store: store
    )
    try await service.resume(
      connections: [connection],
      session: session,
      provider: { _, _, _ in },
      reconcile: { _, _ in throw TestOutboxError.deliveryRejected }
    )

    let attempts = try await service.items(session: session)
    #expect(attempts.first?.state == .userActionRequired)
    #expect(attempts.first?.nextRetryAtMilliseconds == nil)
  }

  @Test
  func testRetryResumesPausedReconciliationWithOriginalIdempotencyKey() async throws {
    let store = InMemoryOutboxDeliveryStore()
    let seedService = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      store: store
    )
    let seeded = try await seedService.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in throw URLError(.notConnectedToInternet) },
      reconcile: { _, _ in .notSent }
    )
    var persisted = try store.load(productAccountId: session.productAccountId)
    persisted[0].state = .handingOff
    try store.save(persisted, productAccountId: session.productAccountId)

    let service = OutboxDeliveryService(
      failureDisposition: { _ in .userActionRequired },
      handoffDelayNanoseconds: immediateHandoffDelay,
      store: store
    )
    try await service.resume(
      connections: [connection],
      session: session,
      provider: { _, _, _ in },
      reconcile: { _, _ in throw TestOutboxError.deliveryRejected }
    )

    let retried = try await service.retry(
      seeded.id,
      connection: connection,
      session: session,
      provider: { _, _, _ in Issue.record("Retry must reconcile before sending.") },
      reconcile: { _, _ in .sent }
    )

    #expect(retried.id == seeded.id)
    #expect(retried.idempotencyKey == seeded.idempotencyKey)
    #expect(retried.state == .reconciling)

    _ = await service.waitForScheduledRetries()
    let completed = try await service.items(session: session)
    #expect(completed.isEmpty)
  }

  @Test
  func testEditRejectsPausedReconciliation() async throws {
    let store = InMemoryOutboxDeliveryStore()
    let seedService = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      store: store
    )
    let seeded = try await seedService.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in throw URLError(.notConnectedToInternet) },
      reconcile: { _, _ in .notSent }
    )
    var persisted = try store.load(productAccountId: session.productAccountId)
    persisted[0].state = .handingOff
    try store.save(persisted, productAccountId: session.productAccountId)

    let service = OutboxDeliveryService(
      failureDisposition: { _ in .userActionRequired },
      handoffDelayNanoseconds: immediateHandoffDelay,
      store: store
    )
    try await service.resume(
      connections: [connection],
      session: session,
      provider: { _, _, _ in },
      reconcile: { _, _ in throw TestOutboxError.deliveryRejected }
    )

    let pausedAttempts = try await service.items(session: session)
    let pausedAttempt = try requireValue(pausedAttempts.first)
    #expect(!(pausedAttempt.canEditOrCancel))

    do {
      _ = try await service.edit(
        seeded.id,
        message: message,
        connection: connection,
        session: session,
        provider: { _, _, _ in },
        reconcile: { _, _ in .notSent }
      )
      Issue.record("Editing must not replace an authorization-paused reconciliation.")
    } catch {
      #expect(error as? OutboxDeliveryError == .attemptCannotBeChanged)
    }
  }

  @Test
  func testCollidedPendingAttemptReschedulesAfterReconciliationStops() async throws {
    let reconciliation = ReconciliationGate()
    let deliveredIds = DeliveryIdRecorder()
    let service = OutboxDeliveryService(
      failureDisposition: { _ in .ambiguous },
      handoffDelayNanoseconds: 1_000_000,
      maximumAttempts: 1,
      retryDelayNanoseconds: { _ in 1_000_000 },
      store: InMemoryOutboxDeliveryStore()
    )
    _ = try await service.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in throw URLError(.timedOut) },
      reconcile: { _, _ in
        await reconciliation.waitForRelease()
        throw TestOutboxError.deliveryRejected
      }
    )
    await reconciliation.waitUntilStarted()

    let second = try await service.enqueue(
      OutgoingMessage(
        body: "Second message",
        recipient: message.recipient,
        subject: message.subject
      ),
      connection: connection,
      session: session,
      provider: { _, idempotencyKey, _ in await deliveredIds.append(idempotencyKey) },
      reconcile: { _, _ in .notSent }
    )
    try await Task.sleep(nanoseconds: 20_000_000)
    await reconciliation.release()
    try await Task.sleep(nanoseconds: 250_000_000)

    let attempts = try await service.items(session: session)
    let delivered = await deliveredIds.values
    #expect(!(attempts.contains(where: { $0.id == second.id })))
    #expect(delivered == [second.idempotencyKey])
  }

  @Test
  func testRestartDoesNotSendRetryAfterMaximumAge() async throws {
    let store = InMemoryOutboxDeliveryStore()
    let clock = LockedOutboxClock(Date(timeIntervalSince1970: 1_781_200_000))
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      now: { clock.now() },
      retryDelayNanoseconds: { _ in 60_000_000_000 },
      store: store
    )
    _ = try await service.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in throw URLError(.notConnectedToInternet) },
      reconcile: { _, _ in .notSent }
    )
    clock.advance(by: 8 * 24 * 60 * 60)
    let deliveries = DeliveryCounter()

    try await service.resume(
      connections: [connection],
      session: session,
      provider: { _, _, _ in await deliveries.increment() },
      reconcile: { _, _ in .notSent }
    )

    let deliveryCount = await deliveries.currentValue()
    #expect(deliveryCount == 0)
    let failedAttempts = try await service.items(session: session)
    #expect(failedAttempts.first?.state == .failed)
  }

  @Test
  func testUnknownOutcomeRequiresExplicitResolutionBeforeRetry() async throws {
    let store = InMemoryOutboxDeliveryStore()
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      store: store
    )
    var attempt = try await service.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in throw URLError(.timedOut) },
      reconcile: { _, _ in .unknown }
    )
    #expect(attempt.state == .outcomeUnknown)
    #expect(!(attempt.state.canEditOrCancel))

    attempt = try await service.resolveUnknownOutcome(
      attempt.id,
      asDelivered: false,
      session: session
    )

    #expect(attempt.state == .failed)
    #expect(attempt.state.canEditOrCancel)
  }

  @Test
  func testEditAndCancelLoseRaceOnceProviderHandoffStarts() async throws {
    let gate = DeliveryHandoffGate()
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      store: InMemoryOutboxDeliveryStore()
    )
    let deliveryTask = Task {
      try await service.enqueue(
        message,
        connection: connection,
        session: session,
        provider: { _, _, _ in await gate.waitForRelease() },
        reconcile: { _, _ in .notSent }
      )
    }
    await gate.waitUntilStarted()
    let attempts = try await service.items(session: session)
    let handingOff = try requireValue(attempts.first)
    #expect(handingOff.state == .handingOff)

    do {
      _ = try await service.cancel(handingOff.id, session: session)
      Issue.record("Cancelling must not replace an attempt during provider handoff.")
    } catch {
      #expect(error as? OutboxDeliveryError == .attemptCannotBeChanged)
    }
    do {
      _ = try await service.edit(
        handingOff.id,
        message: message,
        connection: connection,
        session: session,
        provider: { _, _, _ in },
        reconcile: { _, _ in .notSent }
      )
      Issue.record("Editing must not replace an attempt during provider handoff.")
    } catch {
      #expect(error as? OutboxDeliveryError == .attemptCannotBeChanged)
    }

    await gate.release()
    let delivered = try await deliveryTask.value
    #expect(delivered.state == .sent)
  }

  @Test
  func testReceiveOnlyConnectionCannotEnterOutbox() async throws {
    let receiveOnlyConnection = MailboxConnection(
      authorizationState: .authorized,
      capabilities: .imapRead,
      connectedAt: connection.connectedAt,
      displayName: connection.displayName,
      id: connection.id,
      lastVerifiedAt: connection.lastVerifiedAt,
      productAccountId: connection.productAccountId,
      trustedDeviceId: connection.trustedDeviceId,
      updatedAt: connection.updatedAt
    )
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      store: InMemoryOutboxDeliveryStore()
    )

    do {
      _ = try await service.enqueue(
        message,
        connection: receiveOnlyConnection,
        session: session,
        provider: { _, _, _ in },
        reconcile: { _, _ in .notSent }
      )
      Issue.record("Receive-only connections must not be used for sending.")
    } catch {
      #expect(error as? MailboxConnectionAdapterError == .authorizationRequired)
    }
  }

  @Test
  func testFileStoreEncryptsMessageContentAndClearRemovesIt() async throws {
    let rootDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("outbox-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      retryDelayNanoseconds: { _ in 60_000_000_000 },
      store: FileOutboxDeliveryStore(
        keyMaterialStore: keyStore,
        rootDirectory: rootDirectory
      )
    )

    let semanticDocument = SemanticMessageDocument(
      blocks: [.init(runs: [.init("Private rich text", isBold: true)])]
    )
    let richMessage = OutgoingMessage(
      body: semanticDocument.plainText,
      recipient: message.recipient,
      subject: message.subject,
      htmlBody: semanticDocument.html,
      semanticDocument: semanticDocument
    )

    _ = try await service.enqueue(
      richMessage,
      connection: connection,
      session: session,
      provider: { _, _, _ in throw URLError(.notConnectedToInternet) },
      reconcile: { _, _ in .notSent }
    )

    let fileURL = try requireValue(
      FileManager.default.contentsOfDirectory(
        at: rootDirectory,
        includingPropertiesForKeys: nil
      ).first)
    let persistedText = try requireValue(
      String(data: try Data(contentsOf: fileURL), encoding: .utf8))
    let htmlBody = try requireValue(richMessage.htmlBody)
    #expect(!(persistedText.contains(richMessage.body)))
    #expect(!(persistedText.contains(htmlBody)))
    #expect(!(persistedText.contains("Private rich text")))

    try await service.clear(session: session)
    #expect(
      try FileManager.default.contentsOfDirectory(
        at: rootDirectory,
        includingPropertiesForKeys: nil
      ).isEmpty)
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testStandardsMailSentCopyStoreEncryptsExactMIMEAndClearsConnection() throws {
    let rootDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("sent-copies-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    let store = FileStandardsMailSentCopyStore(
      keyMaterialStore: keyStore,
      rootDirectory: rootDirectory
    )
    let copy = StandardsMailPendingSentCopy(
      connectionId: connection.id,
      idempotencyKey: "accepted-message",
      mailbox: "Sent",
      rawMessage: Data("Message-ID: <accepted-message@example.com>\r\n\r\nSecret body".utf8),
      rfcMessageId: "<accepted-message@example.com>"
    )

    try store.save(
      [copy],
      productAccountId: session.productAccountId,
      connectionId: connection.id
    )

    let accountDirectory = try requireValue(
      FileManager.default.contentsOfDirectory(
        at: rootDirectory,
        includingPropertiesForKeys: nil
      ).first)
    let fileURL = try requireValue(
      FileManager.default.contentsOfDirectory(
        at: accountDirectory,
        includingPropertiesForKeys: nil
      ).first)
    let persistedText = try requireValue(
      String(data: try Data(contentsOf: fileURL), encoding: .utf8))
    #expect(!(persistedText.contains("Secret body")))
    #expect(
      try store.load(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      ) == [copy])

    try store.clear(
      productAccountId: session.productAccountId,
      connectionId: connection.id
    )
    #expect(
      try FileManager.default.contentsOfDirectory(
        at: accountDirectory,
        includingPropertiesForKeys: nil
      ).isEmpty)
  }

  private func graphDraftService(
    cleaner: ProviderDraftCleanerRecorder,
    store: InMemoryOutboxDeliveryStore
  ) -> OutboxDeliveryService {
    OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      providerDraftCleaner: { draftId, connectionId, productAccountId in
        try await cleaner.clean(
          draftId: draftId,
          connectionId: connectionId,
          productAccountId: productAccountId
        )
      },
      retryDelayNanoseconds: { _ in 60_000_000_000 },
      store: store
    )
  }

  private func enqueueDueScheduled(
    _ subject: String,
    service: OutboxDeliveryService,
    provider: @escaping OutboxDeliveryPerformer,
    now: Date
  ) async throws -> OutgoingDeliveryAttempt {
    try await service.enqueueScheduled(
      OutgoingMessage(
        body: "Restored while the connection is busy",
        recipient: message.recipient,
        subject: subject
      ),
      connection: connection,
      session: session,
      scheduleId: UUID(),
      revision: 1,
      dueAt: now,
      deadline: now.addingTimeInterval(24 * 60 * 60),
      undoSendDelayNanoseconds: 0,
      provider: provider,
      reconcile: { _, _ in .notSent }
    )
  }

  private func enqueueRetainedGraphDraft(
    _ draftId: String,
    service: OutboxDeliveryService
  ) async throws -> OutgoingDeliveryAttempt {
    try await service.enqueue(
      message,
      connection: graphConnection,
      session: session,
      provider: { _, _, _ in
        throw MicrosoftGraphSendError(
          stage: .providerHandoff,
          underlyingError: MicrosoftGraphClientError.requestFailed(429),
          providerDraftId: draftId
        )
      },
      reconcile: { _, _ in .notSent }
    )
  }
}

private final class InMemoryOutboxDeliveryStore:
  OutboxDeliveryPersisting, @unchecked Sendable
{
  private var attemptsByProductAccountId: [String: [OutgoingDeliveryAttempt]] = [:]

  func load(productAccountId: String) throws -> [OutgoingDeliveryAttempt] {
    attemptsByProductAccountId[productAccountId] ?? []
  }

  func save(
    _ attempts: [OutgoingDeliveryAttempt],
    productAccountId: String
  ) throws {
    attemptsByProductAccountId[productAccountId] = attempts
  }
}

private final class InMemoryStandardsMailSentCopyStore:
  StandardsMailSentCopyPersisting, @unchecked Sendable
{
  private struct Key: Hashable {
    let connectionId: MailboxConnectionId
    let productAccountId: String
  }

  private var copiesByAccountAndConnection: [Key: [StandardsMailPendingSentCopy]] = [:]

  func clear(productAccountId: String) throws {
    copiesByAccountAndConnection = copiesByAccountAndConnection.filter {
      $0.key.productAccountId != productAccountId
    }
  }

  func clear(
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws {
    copiesByAccountAndConnection[
      Key(connectionId: connectionId, productAccountId: productAccountId)
    ] = nil
  }

  func load(
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws -> [StandardsMailPendingSentCopy] {
    copiesByAccountAndConnection[
      Key(connectionId: connectionId, productAccountId: productAccountId),
      default: []
    ]
  }

  func save(
    _ copies: [StandardsMailPendingSentCopy],
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws {
    copiesByAccountAndConnection[
      Key(connectionId: connectionId, productAccountId: productAccountId)
    ] = copies
  }
}

private enum TestOutboxError: Error {
  case deliveryRejected
  case persistenceFailed
}

private final class FailingOutboxDeliveryStore: OutboxDeliveryPersisting, @unchecked Sendable {
  private let backingStore = InMemoryOutboxDeliveryStore()
  private let failingSaveNumber: Int
  private var saveCount = 0

  init(failingSaveNumber: Int) {
    self.failingSaveNumber = failingSaveNumber
  }

  func load(productAccountId: String) throws -> [OutgoingDeliveryAttempt] {
    try backingStore.load(productAccountId: productAccountId)
  }

  func save(
    _ attempts: [OutgoingDeliveryAttempt],
    productAccountId: String
  ) throws {
    saveCount += 1
    guard saveCount != failingSaveNumber else { throw TestOutboxError.persistenceFailed }
    try backingStore.save(attempts, productAccountId: productAccountId)
  }
}

private actor DeliveryCounter {
  private(set) var value = 0

  func increment() {
    value += 1
  }

  func currentValue() -> Int {
    value
  }
}

@MainActor
private final class ScheduledSendMailboxRoutingSpy: ScheduledSendMailboxRouting {
  private let connections: [MailboxConnection]
  private(set) var sentConnectionIds: [MailboxConnectionId] = []

  init(connections: [MailboxConnection]) {
    self.connections = connections
  }

  func loadConnections(
    session _: ProductAccountSessionSnapshot
  ) async throws -> [MailboxConnection] {
    connections
  }

  func send(
    _: OutgoingMessage,
    connection: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws {
    sentConnectionIds.append(connection.id)
  }

  func deliveryStatus(
    idempotencyKey _: String,
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxDeliveryStatus {
    .notSent
  }
}

private actor ScheduledSendClaimTransportSpy: ScheduledSendOperationalTransport {
  private var claimPhase = ScheduledSendClaimPhase.preHandoff
  private var recordedEvents: [String] = []

  func admitScheduledSend(
    _ record: ScheduledSendRecord,
    payload: ScheduledSendPayloadAcknowledgement,
    session _: ProductAccountSessionSnapshot
  ) async throws -> ScheduledSendOperationalAcknowledgement {
    ScheduledSendOperationalAcknowledgement(
      dueAt: record.dueAtMilliseconds,
      encryptedPayloadUpdatedAt: payload.updatedAt,
      revision: record.revision,
      scheduleId: record.scheduleId.uuidString.lowercased()
    )
  }

  func cancelScheduledSend(
    scheduleId _: UUID,
    revision _: Int,
    session _: ProductAccountSessionSnapshot
  ) async throws -> Bool { true }

  func registerScheduledDeliveryCapability(
    session _: ProductAccountSessionSnapshot
  ) async throws -> ScheduledDeliveryAuthorization {
    ScheduledDeliveryAuthorization(
      authorization: "authorization", capabilityVersion: 1, generation: 1)
  }

  func claimScheduledSend(
    scheduleId _: UUID,
    revision _: Int,
    trustedDeviceId _: String
  ) async throws -> ScheduledSendClaimResult {
    recordedEvents.append("claim")
    return .claimed(
      ScheduledSendClaim(
        authorizationGeneration: 1,
        expiresAt: 1_800_001_000_000,
        generation: 7,
        phase: .preHandoff
      )
    )
  }

  func advanceScheduledSendClaimToHandoff(
    scheduleId _: UUID,
    revision _: Int,
    claimGeneration _: Int,
    trustedDeviceId _: String
  ) async throws -> Bool {
    recordedEvents.append("advance")
    claimPhase = .handingOff
    return true
  }

  func revalidateScheduledSendClaim(
    scheduleId _: UUID,
    revision _: Int,
    claimGeneration: Int,
    trustedDeviceId _: String
  ) async throws -> ScheduledSendClaimResult {
    .claimed(
      ScheduledSendClaim(
        authorizationGeneration: 1,
        expiresAt: nil,
        generation: claimGeneration,
        phase: claimPhase
      )
    )
  }

  func releaseScheduledSendClaim(
    scheduleId _: UUID,
    revision _: Int,
    claimGeneration _: Int,
    trustedDeviceId _: String
  ) async throws -> Bool { true }

  func completeScheduledSendClaim(
    scheduleId _: UUID,
    revision _: Int,
    claimGeneration _: Int,
    state _: ScheduledSendCompletionState,
    trustedDeviceId _: String
  ) async throws -> Bool {
    recordedEvents.append("complete")
    return true
  }

  func recordProviderHandoff() {
    recordedEvents.append("provider")
  }

  func events() -> [String] {
    recordedEvents
  }
}

actor InMemoryScheduledSendPayloadSync: ScheduledSendPayloadSyncing {
  private var snapshots: [ScheduledSendPayloadSnapshot]

  init(snapshots: [ScheduledSendPayloadSnapshot] = []) {
    self.snapshots = snapshots
  }

  func load(
    scheduleId: UUID,
    session _: ProductAccountSessionSnapshot
  ) async throws -> ScheduledSendRecord? {
    snapshots.filter { $0.record.scheduleId == scheduleId }
      .max { $0.record.revision < $1.record.revision }?.record
  }

  func list(
    session _: ProductAccountSessionSnapshot
  ) async throws -> [ScheduledSendPayloadSnapshot] { snapshots }

  func load(
    scheduleId: UUID,
    revision: Int,
    session _: ProductAccountSessionSnapshot
  ) async throws -> ScheduledSendPayloadSnapshot? {
    snapshots.first {
      $0.record.scheduleId == scheduleId && $0.record.revision == revision
    }
  }

  func remove(
    scheduleId: UUID,
    session _: ProductAccountSessionSnapshot
  ) async throws {
    snapshots.removeAll { $0.record.scheduleId == scheduleId }
  }

  func remove(
    scheduleId: UUID,
    revision: Int,
    session _: ProductAccountSessionSnapshot
  ) async throws {
    snapshots.removeAll {
      $0.record.scheduleId == scheduleId && $0.record.revision == revision
    }
  }

  func save(
    _ record: ScheduledSendRecord,
    session _: ProductAccountSessionSnapshot
  ) async throws -> ScheduledSendPayloadAcknowledgement {
    let acknowledgement = ScheduledSendPayloadAcknowledgement(
      payloadIdentifier: "payload-\(record.revision)",
      updatedAt: Int64(record.revision * 100)
    )
    snapshots.append(
      ScheduledSendPayloadSnapshot(acknowledgement: acknowledgement, record: record)
    )
    return acknowledgement
  }
}

private actor ScheduledSendManagementTransportSpy: ScheduledSendOperationalTransport {
  private var beginEditCalls = 0
  private var replacementRevision: Int?
  private let status: ScheduledSendOperationalStatus

  init(status: ScheduledSendOperationalStatus) {
    self.status = status
  }

  func admitScheduledSend(
    _ record: ScheduledSendRecord,
    payload: ScheduledSendPayloadAcknowledgement,
    session _: ProductAccountSessionSnapshot
  ) async throws -> ScheduledSendOperationalAcknowledgement {
    acknowledgement(record, payload: payload)
  }

  func cancelScheduledSend(
    scheduleId _: UUID,
    revision _: Int,
    session _: ProductAccountSessionSnapshot
  ) async throws -> Bool { true }

  func scheduledSendStatus(
    scheduleId _: UUID,
    session _: ProductAccountSessionSnapshot
  ) async throws -> ScheduledSendOperationalStatus? { status }

  func beginScheduledSendEdit(
    scheduleId _: UUID,
    revision _: Int,
    session _: ProductAccountSessionSnapshot
  ) async throws -> ScheduledSendEditLeaseResult {
    beginEditCalls += 1
    return .acquired(ScheduledSendEditLease(expiresAt: 1_800_001_000_000, generation: 7))
  }

  func rescheduleScheduledSend(
    _ record: ScheduledSendRecord,
    payload: ScheduledSendPayloadAcknowledgement,
    expectedRevision _: Int,
    editGeneration _: Int,
    session _: ProductAccountSessionSnapshot
  ) async throws -> ScheduledSendOperationalAcknowledgement {
    replacementRevision = record.revision
    return acknowledgement(record, payload: payload)
  }

  func registerScheduledDeliveryCapability(
    session _: ProductAccountSessionSnapshot
  ) async throws -> ScheduledDeliveryAuthorization {
    ScheduledDeliveryAuthorization(
      authorization: "authorization",
      capabilityVersion: 1,
      generation: 1
    )
  }

  func claimScheduledSend(
    scheduleId _: UUID,
    revision _: Int,
    trustedDeviceId _: String
  ) async throws -> ScheduledSendClaimResult { .unavailable }

  func advanceScheduledSendClaimToHandoff(
    scheduleId _: UUID,
    revision _: Int,
    claimGeneration _: Int,
    trustedDeviceId _: String
  ) async throws -> Bool { false }

  func revalidateScheduledSendClaim(
    scheduleId _: UUID,
    revision _: Int,
    claimGeneration _: Int,
    trustedDeviceId _: String
  ) async throws -> ScheduledSendClaimResult { .unavailable }

  func releaseScheduledSendClaim(
    scheduleId _: UUID,
    revision _: Int,
    claimGeneration _: Int,
    trustedDeviceId _: String
  ) async throws -> Bool { false }

  func completeScheduledSendClaim(
    scheduleId _: UUID,
    revision _: Int,
    claimGeneration _: Int,
    state _: ScheduledSendCompletionState,
    trustedDeviceId _: String
  ) async throws -> Bool { false }

  func beginEditCallCount() -> Int { beginEditCalls }

  func rescheduledRevision() -> Int? { replacementRevision }

  private func acknowledgement(
    _ record: ScheduledSendRecord,
    payload: ScheduledSendPayloadAcknowledgement
  ) -> ScheduledSendOperationalAcknowledgement {
    ScheduledSendOperationalAcknowledgement(
      dueAt: record.dueAtMilliseconds,
      encryptedPayloadUpdatedAt: payload.updatedAt,
      revision: record.revision,
      scheduleId: record.scheduleId.uuidString.lowercased()
    )
  }
}

private actor DeliveryCancellationRecorder {
  private var cancelled = false

  func record(_ value: Bool) {
    cancelled = value
  }

  func wasCancelled() -> Bool {
    cancelled
  }
}

private actor ProviderDraftCleanerRecorder {
  private var attempts = 0
  private var draftIds: [String] = []
  private var remainingFailures: Int
  private let suspendedAttempt: Int?
  private var suspendedAttemptContinuation: CheckedContinuation<Void, Never>?
  private var suspendedAttemptReached = false
  private var suspendedAttemptWaiters: [CheckedContinuation<Void, Never>] = []

  init(failureCount: Int = 0, suspendedAttempt: Int? = nil) {
    remainingFailures = failureCount
    self.suspendedAttempt = suspendedAttempt
  }

  func clean(
    draftId: String,
    connectionId _: MailboxConnectionId,
    productAccountId _: String
  ) async throws {
    attempts += 1
    if remainingFailures > 0 {
      remainingFailures -= 1
      throw TestOutboxError.deliveryRejected
    }
    if attempts == suspendedAttempt {
      suspendedAttemptReached = true
      for waiter in suspendedAttemptWaiters {
        waiter.resume()
      }
      suspendedAttemptWaiters.removeAll()
      await withCheckedContinuation { continuation in
        suspendedAttemptContinuation = continuation
      }
    }
    draftIds.append(draftId)
  }

  func waitUntilSuspended() async {
    guard !suspendedAttemptReached else { return }
    await withCheckedContinuation { continuation in
      suspendedAttemptWaiters.append(continuation)
    }
  }

  func resumeSuspendedAttempt() {
    suspendedAttemptContinuation?.resume()
    suspendedAttemptContinuation = nil
  }

  func attemptCount() -> Int {
    attempts
  }

  func deletedDraftIds() -> [String] {
    draftIds
  }
}

private actor SuspendingDelivery {
  private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
  private var wasCancelled = false
  private var wasStarted = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []

  func started() {
    wasStarted = true
    for waiter in startWaiters {
      waiter.resume()
    }
    startWaiters.removeAll()
  }

  func cancelled() {
    wasCancelled = true
    for waiter in cancellationWaiters {
      waiter.resume()
    }
    cancellationWaiters.removeAll()
  }

  func waitUntilCancelled() async {
    guard !wasCancelled else { return }
    await withCheckedContinuation { cancellationWaiters.append($0) }
  }

  func waitUntilStarted() async {
    guard !wasStarted else { return }
    await withCheckedContinuation { startWaiters.append($0) }
  }
}

private actor DeliveryIdRecorder {
  private(set) var values: [String] = []

  func append(_ value: String) {
    values.append(value)
  }
}

private actor TransientSecondMessageDelivery {
  private var secondMessageAttemptCount = 0

  func deliver(_ message: OutgoingMessage) throws {
    guard message.subject == "Second" else { return }
    secondMessageAttemptCount += 1
    if secondMessageAttemptCount == 1 {
      throw URLError(.notConnectedToInternet)
    }
  }

  func attemptCount() -> Int {
    secondMessageAttemptCount
  }
}

private actor DeliveryHandoffGate {
  private var releaseContinuation: CheckedContinuation<Void, Never>?
  private var started = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []

  func waitForRelease() async {
    started = true
    for waiter in startWaiters {
      waiter.resume()
    }
    startWaiters.removeAll()
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
  }

  func waitUntilStarted() async {
    guard !started else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}

private actor ReconciliationGate {
  private var releaseContinuation: CheckedContinuation<Void, Never>?
  private var started = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []

  func waitForRelease() async {
    started = true
    for waiter in startWaiters {
      waiter.resume()
    }
    startWaiters.removeAll()
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
  }

  func waitUntilStarted() async {
    guard !started else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}

private final class LockedOutboxClock: @unchecked Sendable {
  private var date: Date
  private let lock = NSLock()

  init(_ date: Date) {
    self.date = date
  }

  func advance(by interval: TimeInterval) {
    lock.withLock {
      date = date.addingTimeInterval(interval)
    }
  }

  func now() -> Date {
    lock.withLock { date }
  }
}
