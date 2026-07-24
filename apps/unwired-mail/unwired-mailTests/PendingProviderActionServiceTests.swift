import XCTest

@testable import unwired_mail

// swiftlint:disable file_length type_body_length

@MainActor
final class PendingProviderActionServiceTests: XCTestCase {
  private let connection = GmailProviderConnectionStatus(
    connectedAt: 1_781_200_000_000,
    emailAddress: "reader@example.com",
    lastVerifiedAt: 1_781_200_000_100,
    provider: "gmail",
    providerAccountIdentifier: "gmail-user-001",
    trustedDeviceId: "trusted-device-001",
    updatedAt: 1_781_200_000_200
  ).mailboxConnection(productAccountId: "product-account-001")

  private let session = ProductAccountSessionSnapshot(
    appleUserIdentifier: "apple-user-001",
    identityToken: "product-token",
    productAccountId: "product-account-001",
    trustedDeviceId: "trusted-device-001"
  )

  func testOfflineArchivePersistsAndProjectsImmediately() async throws {
    let store = InMemoryPendingProviderActionStore()
    let service = PendingProviderActionService(
      retryDelayNanoseconds: { _ in 60_000_000_000 },
      store: store
    )
    let message = pendingActionMessage(
      providerMessageId: "message-001",
      providerStateIds: ["INBOX", "UNREAD"]
    )

    try await service.perform(
      .archive,
      messages: [message],
      connection: connection,
      session: session
    ) { _, _, _ in
      throw URLError(.notConnectedToInternet)
    }

    let projected = try await service.project(
      MailboxMetadataSyncResult(
        hasUnlistedNewMessages: false,
        messages: [message],
        newMessageIds: nil,
        providerCursorIsExpired: false,
        threads: MailboxThread.group([message])
      ),
      connection: connection,
      session: session
    )

    XCTAssertEqual(try store.load(productAccountId: session.productAccountId).count, 1)
    XCTAssertTrue(projected.messages.isEmpty)
  }

  func testFailureDetailsExcludePendingActions() async throws {
    let service = PendingProviderActionService(store: InMemoryPendingProviderActionStore())
    let message = pendingActionMessage(
      providerMessageId: "message-pending",
      providerStateIds: ["INBOX"]
    )

    try await service.perform(
      .archive,
      messages: [message],
      connection: connection,
      session: session
    ) { _, _, _ in
      throw URLError(.notConnectedToInternet)
    }

    let details = try await service.failureDetails(
      .archive,
      messageIds: [message.providerMessageId],
      connection: connection,
      session: session
    )

    XCTAssertEqual(details, [])
  }

  func testPendingActionsResumeInOrderAfterRestart() async throws {
    let store = InMemoryPendingProviderActionStore()
    let firstService = PendingProviderActionService(
      retryDelayNanoseconds: { _ in 60_000_000_000 },
      store: store
    )
    let firstMessage = pendingActionMessage(
      providerMessageId: "message-001",
      providerStateIds: ["INBOX", "UNREAD"]
    )
    let secondMessage = pendingActionMessage(
      providerMessageId: "message-002",
      providerStateIds: ["INBOX", "UNREAD"]
    )
    let offline: PendingProviderActionPerformer = { _, _, _ in
      throw URLError(.notConnectedToInternet)
    }

    try await firstService.perform(
      .archive,
      messages: [firstMessage],
      connection: connection,
      session: session,
      provider: offline
    )
    try await firstService.perform(
      .markRead,
      messages: [secondMessage],
      connection: connection,
      session: session,
      provider: offline
    )

    let recorder = PendingProviderActionRecorder()
    let restartedService = PendingProviderActionService(store: store)
    try await restartedService.resume(
      connection: connection,
      session: session
    ) { action, _, messageIds in
      await recorder.record(action: action, messageIds: messageIds)
    }

    let calls = await recorder.calls
    XCTAssertEqual(calls.map(\.action), [.archive, .markRead])
    XCTAssertEqual(calls.map(\.messageIds), [["message-001"], ["message-002"]])
    XCTAssertEqual(
      try store.load(productAccountId: session.productAccountId).map(\.state),
      [.providerConfirmed, .providerConfirmed]
    )
  }

  func testProviderSyncReconcilesConfirmedActionWithoutReplayingIt() async throws {
    let store = InMemoryPendingProviderActionStore()
    let service = PendingProviderActionService(store: store)
    let message = pendingActionMessage(
      providerMessageId: "message-001",
      providerStateIds: ["INBOX"]
    )
    let recorder = PendingProviderActionRecorder()

    try await service.perform(
      .archive,
      messages: [message],
      connection: connection,
      session: session
    ) { action, _, messageIds in
      await recorder.record(action: action, messageIds: messageIds)
    }
    try await service.reconcileProviderSync(
      messages: [
        pendingActionMessage(
          providerMessageId: "message-001",
          providerStateIds: []
        )
      ],
      connection: connection,
      session: session
    )
    try await service.resume(
      connection: connection,
      session: session
    ) { action, _, messageIds in
      await recorder.record(action: action, messageIds: messageIds)
    }

    let callCount = await recorder.calls.count
    XCTAssertEqual(callCount, 1)
    XCTAssertTrue(try store.load(productAccountId: session.productAccountId).isEmpty)
    let providerConflict = try await service.project(
      MailboxMetadataSyncResult(
        hasUnlistedNewMessages: false,
        messages: [message],
        newMessageIds: nil,
        providerCursorIsExpired: false,
        threads: MailboxThread.group([message])
      ),
      connection: connection,
      session: session
    )
    XCTAssertEqual(providerConflict.messages, [message])
  }

  func testFullCapabilityActionsProjectProviderState() async throws {
    // swiftlint:disable:next large_tuple
    let cases: [(ProviderMailAction, String?, [String], Set<String>)] = [
      (.markRead, nil, ["INBOX", "UNREAD"], ["INBOX"]),
      (.markUnread, nil, ["INBOX"], ["INBOX", "UNREAD"]),
      (.archive, nil, ["INBOX"], []),
      (.move, "Label_projects", ["INBOX"], ["Label_projects"]),
      (.delete, nil, ["INBOX"], ["TRASH"]),
      (.restore, nil, ["TRASH"], ["INBOX"]),
      (.spam, nil, ["INBOX"], ["SPAM"]),
      (.notSpam, nil, ["SPAM"], ["INBOX"]),
      (.star, nil, ["INBOX"], ["INBOX", "STARRED"]),
      (.unstar, nil, ["INBOX", "STARRED"], ["INBOX"]),
    ]

    for (index, testCase) in cases.enumerated() {
      let store = InMemoryPendingProviderActionStore()
      let service = PendingProviderActionService(
        retryDelayNanoseconds: { _ in 60_000_000_000 },
        store: store
      )
      let message = pendingActionMessage(
        providerMessageId: "message-\(index)",
        providerStateIds: testCase.2
      )
      try await service.perform(
        testCase.0,
        targetProviderMailboxId: testCase.1,
        messages: [message],
        connection: connection,
        session: session
      ) { _, _, _ in
        throw URLError(.notConnectedToInternet)
      }

      let projected = try await service.project(
        MailboxMetadataSyncResult(
          hasUnlistedNewMessages: false,
          messages: [message],
          newMessageIds: nil,
          providerCursorIsExpired: false,
          threads: MailboxThread.group([message])
        ),
        collection: .allObserved,
        connection: connection,
        session: session
      )

      XCTAssertEqual(Set(projected.messages[0].providerStateIds ?? []), testCase.3)
    }
  }

  // swiftlint:disable:next function_body_length
  func testPermanentRejectionRestoresProviderStateAndReplaysLaterIntent() async throws {
    let store = InMemoryPendingProviderActionStore()
    let offlineService = PendingProviderActionService(
      retryDelayNanoseconds: { _ in 60_000_000_000 },
      store: store
    )
    let archivedMessage = pendingActionMessage(
      providerMessageId: "message-archive",
      providerStateIds: ["INBOX"]
    )
    let readMessage = pendingActionMessage(
      providerMessageId: "message-read",
      providerStateIds: ["INBOX", "UNREAD"]
    )
    let offline: PendingProviderActionPerformer = { _, _, _ in
      throw URLError(.notConnectedToInternet)
    }
    try await offlineService.perform(
      .archive,
      messages: [archivedMessage],
      connection: connection,
      session: session,
      provider: offline
    )
    try await offlineService.perform(
      .markRead,
      messages: [readMessage],
      connection: connection,
      session: session,
      provider: offline
    )

    let recorder = PendingProviderActionRecorder()
    let service = PendingProviderActionService(
      failureDisposition: { _ in .permanent },
      store: store
    )
    do {
      try await service.resume(connection: connection, session: session) { action, _, messageIds in
        await recorder.record(action: action, messageIds: messageIds)
        if action == .archive {
          throw PendingProviderActionTestError.rejected
        }
      }
      XCTFail("Expected permanent rejection")
    } catch let error as PendingProviderActionTestError {
      guard case .rejected = error else {
        return XCTFail("Expected provider rejection")
      }
    }

    let calls = await recorder.calls
    XCTAssertEqual(calls.map(\.action), [.archive, .markRead])
    XCTAssertEqual(
      try store.load(productAccountId: session.productAccountId).map(\.state),
      [.failed, .providerConfirmed]
    )
    let projected = try await service.project(
      MailboxMetadataSyncResult(
        hasUnlistedNewMessages: false,
        messages: [archivedMessage, readMessage],
        newMessageIds: nil,
        providerCursorIsExpired: false,
        threads: MailboxThread.group([archivedMessage, readMessage])
      ),
      collection: .allObserved,
      connection: connection,
      session: session
    )
    XCTAssertEqual(
      Set(projected.messages.first { $0.id == archivedMessage.id }?.providerStateIds ?? []),
      ["INBOX"]
    )
    XCTAssertEqual(
      Set(projected.messages.first { $0.id == readMessage.id }?.providerStateIds ?? []),
      ["INBOX"]
    )
  }

  func testTransientFailureRetriesAutomatically() async throws {
    let recorder = PendingProviderActionRecorder()
    let service = PendingProviderActionService(
      retryDelayNanoseconds: { _ in 1_000_000 },
      store: InMemoryPendingProviderActionStore()
    )
    let message = pendingActionMessage(
      providerMessageId: "message-retry",
      providerStateIds: ["INBOX"]
    )

    try await service.perform(
      .archive,
      messages: [message],
      connection: connection,
      session: session
    ) { action, _, messageIds in
      let callCount = await recorder.recordAndCount(action: action, messageIds: messageIds)
      if callCount == 1 {
        throw URLError(.timedOut)
      }
    }

    for _ in 0..<100 {
      if try await service.pendingActions(session: session).first?.state == .providerConfirmed {
        break
      }
      try await Task.sleep(nanoseconds: 1_000_000)
    }

    let callCount = await recorder.calls.count
    let actionState = try await service.pendingActions(session: session).first?.state
    XCTAssertEqual(callCount, 2)
    XCTAssertEqual(actionState, .providerConfirmed)
  }

  func testResumeWaitsForScheduledRetry() async throws {
    let recorder = PendingProviderActionRecorder()
    let service = PendingProviderActionService(
      retryDelayNanoseconds: { _ in 60_000_000_000 },
      store: InMemoryPendingProviderActionStore()
    )
    let message = pendingActionMessage(
      providerMessageId: "message-backoff",
      providerStateIds: ["INBOX"]
    )

    try await service.perform(
      .archive,
      messages: [message],
      connection: connection,
      session: session
    ) { action, _, messageIds in
      await recorder.record(action: action, messageIds: messageIds)
      throw URLError(.timedOut)
    }
    try await service.resume(
      connection: connection,
      session: session
    ) { action, _, messageIds in
      await recorder.record(action: action, messageIds: messageIds)
    }

    let calls = await recorder.calls
    XCTAssertEqual(calls.count, 1)
    try await service.clear(session: session)
  }

  func testBulkActionPersistsPerMessageAndKeepsPartialProviderSuccess() async throws {
    let store = InMemoryPendingProviderActionStore()
    let service = PendingProviderActionService(
      failureDisposition: { _ in .permanent },
      store: store
    )
    let firstMessage = pendingActionMessage(
      providerMessageId: "message-first",
      providerStateIds: ["INBOX"]
    )
    let secondMessage = pendingActionMessage(
      providerMessageId: "message-second",
      providerStateIds: ["INBOX"]
    )
    let recorder = PendingProviderActionRecorder()

    do {
      try await service.perform(
        .archive,
        messages: [firstMessage, secondMessage],
        connection: connection,
        session: session
      ) { action, _, messageIds in
        await recorder.record(action: action, messageIds: messageIds)
        if messageIds == ["message-second"] {
          throw PendingProviderActionTestError.rejected
        }
      }
      XCTFail("Expected the second provider action to fail")
    } catch let error as PendingProviderActionTestError {
      guard case .rejected = error else {
        return XCTFail("Expected provider rejection")
      }
    }

    let actions = try store.load(productAccountId: session.productAccountId)
    let calls = await recorder.calls
    XCTAssertEqual(calls.map(\.messageIds), [["message-first"], ["message-second"]])
    XCTAssertEqual(actions.map(\.messageIds), [["message-first"], ["message-second"]])
    XCTAssertEqual(actions.map(\.state), [.providerConfirmed, .failed])
  }

  func testCredentialFailuresRequireUserActionWithoutRollingBackOptimism() async throws {
    let credentialErrors: [GmailMessageMetadataSyncError] = [
      .insufficientGmailScope,
      .missingLocalGmailTokens,
      .refreshedTokenAccountMismatch,
      .refreshTokenRejected,
    ]

    for (index, credentialError) in credentialErrors.enumerated() {
      let store = InMemoryPendingProviderActionStore()
      let service = PendingProviderActionService(store: store)
      let message = pendingActionMessage(
        providerMessageId: "message-credential-\(index)",
        providerStateIds: ["INBOX"]
      )
      do {
        try await service.perform(
          .archive,
          messages: [message],
          connection: connection,
          session: session
        ) { _, _, _ in
          throw credentialError
        }
        XCTFail("Expected credential failure")
      } catch let error as PendingProviderActionError {
        guard case .retryLimitReached = error else {
          return XCTFail("Expected user-action-required failure")
        }
      }
      XCTAssertEqual(
        try store.load(productAccountId: session.productAccountId).first?.state,
        .userActionRequired
      )
    }
  }

  // swiftlint:disable:next function_body_length
  func testBlockedActionRequiresExplicitRetryOrDiscard() async throws {
    let store = InMemoryPendingProviderActionStore()
    let service = PendingProviderActionService(maximumAttempts: 1, store: store)
    let blockedMessage = pendingActionMessage(
      providerMessageId: "message-blocked",
      providerStateIds: ["INBOX"]
    )
    let laterMessage = pendingActionMessage(
      providerMessageId: "message-later",
      providerStateIds: ["INBOX", "UNREAD"]
    )
    let recorder = PendingProviderActionRecorder()

    do {
      try await service.perform(
        .archive,
        messages: [blockedMessage],
        connection: connection,
        session: session
      ) { action, _, messageIds in
        await recorder.record(action: action, messageIds: messageIds)
        throw URLError(.timedOut)
      }
    } catch let error as PendingProviderActionError {
      guard case .retryLimitReached = error else {
        return XCTFail("Expected retry-limit failure")
      }
    } catch {
      XCTFail("Expected timeout, got \\(error)")
    }
    try await service.enqueue(
      .markRead,
      messages: [laterMessage],
      connection: connection,
      session: session
    )

    do {
      try await service.resume(
        connection: connection,
        session: session
      ) { action, _, messageIds in
        await recorder.record(action: action, messageIds: messageIds)
      }
      XCTFail("Expected the terminal action to block ordinary resume")
    } catch let error as PendingProviderActionError {
      guard case .retryLimitReached = error else {
        return XCTFail("Expected retry-limit failure")
      }
    }
    var calls = await recorder.calls
    XCTAssertEqual(calls.count, 1)

    try await service.discardBlockedAction(
      connection: connection,
      session: session
    ) { action, _, messageIds in
      await recorder.record(action: action, messageIds: messageIds)
    }
    calls = await recorder.calls
    XCTAssertEqual(calls.map(\.action), [.archive, .markRead])
    XCTAssertEqual(
      try store.load(productAccountId: session.productAccountId).map(\.state),
      [.providerConfirmed]
    )
  }

  func testExplicitRetryResumesBlockedActionAfterAuthorizationRepair() async throws {
    let store = InMemoryPendingProviderActionStore()
    let service = PendingProviderActionService(store: store)
    let message = pendingActionMessage(
      providerMessageId: "message-reauthorized",
      providerStateIds: ["INBOX"]
    )
    do {
      try await service.perform(
        .archive,
        messages: [message],
        connection: connection,
        session: session
      ) { _, _, _ in
        throw GmailMessageMetadataSyncError.missingLocalGmailTokens
      }
    } catch let error as PendingProviderActionError {
      guard case .retryLimitReached = error else {
        return XCTFail("Expected retry-limit failure")
      }
    } catch {
      XCTFail("Expected missing-local-token failure, got \\(error)")
    }

    try await service.retryBlockedAction(
      connection: connection,
      session: session
    ) { _, _, _ in }

    XCTAssertEqual(
      try store.load(productAccountId: session.productAccountId).first?.state,
      .providerConfirmed
    )
  }

  // swiftlint:disable:next function_body_length
  func testRetryLimitKeepsOptimisticStateAndReportsFailure() async throws {
    let recorder = PendingProviderActionRecorder()
    let service = PendingProviderActionService(
      maximumAttempts: 2,
      retryDelayNanoseconds: { _ in 1_000_000 },
      store: InMemoryPendingProviderActionStore()
    )
    let message = pendingActionMessage(
      providerMessageId: "message-retry-limit",
      providerStateIds: ["INBOX"]
    )
    let unavailable: PendingProviderActionPerformer = { action, _, messageIds in
      await recorder.record(action: action, messageIds: messageIds)
      throw URLError(.timedOut)
    }

    try await service.perform(
      .archive,
      messages: [message],
      connection: connection,
      session: session,
      provider: unavailable
    )
    await service.waitForScheduledRetries(connection: connection, session: session)

    let actionState = try await service.pendingActions(session: session).first?.state
    let failureDescription = try await service.failureDescription(
      connection: connection,
      session: session
    )
    let projected = try await service.project(
      MailboxMetadataSyncResult(
        hasUnlistedNewMessages: false,
        messages: [message],
        newMessageIds: nil,
        providerCursorIsExpired: false,
        threads: MailboxThread.group([message])
      ),
      connection: connection,
      session: session
    )
    XCTAssertEqual(actionState, .userActionRequired)
    XCTAssertNotNil(failureDescription)
    XCTAssertTrue(projected.messages.isEmpty)

    do {
      try await service.resume(
        connection: connection,
        session: session,
        provider: unavailable
      )
      XCTFail("Expected retry-limit failure")
    } catch let error as PendingProviderActionError {
      guard case .retryLimitReached = error else {
        return XCTFail("Expected retry-limit failure")
      }
    }
  }

  func testPermanentFailureRemainsDurableUntilAcknowledged() async throws {
    let store = InMemoryPendingProviderActionStore()
    let service = PendingProviderActionService(
      failureDisposition: { _ in .permanent },
      store: store
    )
    let message = pendingActionMessage(
      providerMessageId: "message-permanent",
      providerStateIds: ["INBOX"]
    )
    do {
      try await service.perform(
        .archive,
        messages: [message],
        connection: connection,
        session: session
      ) { _, _, _ in
        throw PendingProviderActionTestError.rejected
      }
    } catch let error as PendingProviderActionTestError {
      guard case .rejected = error else {
        return XCTFail("Expected provider rejection")
      }
    } catch {
      XCTFail("Expected provider rejection, got \\(error)")
    }

    let backgroundRead = try await service.failureDescription(
      connection: connection,
      session: session
    )
    let foregroundRead = try await service.failureDescription(
      connection: connection,
      session: session
    )
    XCTAssertEqual(backgroundRead, foregroundRead)
    var hasFailedAction = try await service.hasFailedAction(
      connection: connection,
      session: session
    )
    XCTAssertTrue(hasFailedAction)

    try await service.acknowledgeFailures(connection: connection, session: session)
    hasFailedAction = try await service.hasFailedAction(
      connection: connection,
      session: session
    )
    XCTAssertFalse(hasFailedAction)
  }

  func testProviderSyncClearsBlockedActionWhenProviderStateMatches() async throws {
    let store = InMemoryPendingProviderActionStore()
    let service = PendingProviderActionService(store: store)
    let message = pendingActionMessage(
      providerMessageId: "message-blocked-archive",
      providerStateIds: ["INBOX"]
    )

    do {
      try await service.perform(
        .archive,
        messages: [message],
        connection: connection,
        session: session
      ) { _, _, _ in
        throw GmailMessageMetadataSyncError.missingLocalGmailTokens
      }
      XCTFail("Expected retry-limit failure")
    } catch let error as PendingProviderActionError {
      guard case .retryLimitReached = error else {
        return XCTFail("Expected retry-limit failure")
      }
    }

    try await service.reconcileProviderSync(
      messages: [
        pendingActionMessage(
          providerMessageId: "message-blocked-archive",
          providerStateIds: []
        )
      ],
      connection: connection,
      session: session
    )

    let actions = try await service.pendingActions(session: session)
    XCTAssertTrue(actions.isEmpty)
  }

  func testDeleteProjectionRemovesSpam() async throws {
    let service = PendingProviderActionService(store: InMemoryPendingProviderActionStore())
    let message = pendingActionMessage(
      providerMessageId: "message-spam-delete",
      providerStateIds: ["SPAM"]
    )

    try await service.perform(
      .delete,
      messages: [message],
      connection: connection,
      session: session
    ) { _, _, _ in }
    let projected = try await service.project(
      MailboxMetadataSyncResult(
        hasUnlistedNewMessages: false,
        messages: [message],
        newMessageIds: nil,
        providerCursorIsExpired: false,
        threads: MailboxThread.group([message])
      ),
      collection: .role(.spam),
      connection: connection,
      session: session
    )

    XCTAssertTrue(projected.messages.isEmpty)
  }

  func testDeleteProjectionRemovesProviderMailboxLabels() async throws {
    let service = PendingProviderActionService(store: InMemoryPendingProviderActionStore())
    let message = pendingActionMessage(
      providerMessageId: "message-provider-label-delete",
      providerStateIds: ["Label_projects", "STARRED"]
    )

    let result = MailboxMetadataSyncResult(
      hasUnlistedNewMessages: false,
      messages: [message],
      newMessageIds: nil,
      providerCursorIsExpired: false,
      threads: MailboxThread.group([message])
    )
    let initiallyProjected = try await service.project(
      result,
      collection: .providerMailbox("Label_projects"),
      connection: connection,
      session: session
    )
    XCTAssertEqual(initiallyProjected.messages, [message])

    try await service.perform(
      .delete,
      messages: [message],
      connection: connection,
      session: session
    ) { _, _, _ in }
    let projected = try await service.project(
      result,
      collection: .providerMailbox("Label_projects"),
      connection: connection,
      session: session
    )

    XCTAssertTrue(projected.messages.isEmpty)
  }

  func testProviderSyncReconcilesMoveToInbox() async throws {
    let store = InMemoryPendingProviderActionStore()
    let service = PendingProviderActionService(store: store)
    let message = pendingActionMessage(
      providerMessageId: "message-move-inbox",
      providerStateIds: ["Label_projects"]
    )

    try await service.perform(
      .move,
      targetProviderMailboxId: "INBOX",
      messages: [message],
      connection: connection,
      session: session
    ) { _, _, _ in }
    try await service.reconcileProviderSync(
      messages: [
        pendingActionMessage(
          providerMessageId: "message-move-inbox",
          providerStateIds: ["INBOX"]
        )
      ],
      connection: connection,
      session: session
    )

    let pendingActions = try await service.pendingActions(session: session)
    XCTAssertTrue(pendingActions.isEmpty)
  }

  func testProviderSyncRemovesSupersededConfirmedAction() async throws {
    let store = InMemoryPendingProviderActionStore()
    let service = PendingProviderActionService(store: store)
    let message = pendingActionMessage(
      providerMessageId: "message-superseded",
      providerStateIds: ["INBOX", "UNREAD"]
    )

    try await service.perform(
      .markRead,
      messages: [message],
      connection: connection,
      session: session
    ) { _, _, _ in }
    try await service.perform(
      .markUnread,
      messages: [message],
      connection: connection,
      session: session
    ) { _, _, _ in }
    try await service.reconcileProviderSync(
      messages: [message],
      connection: connection,
      session: session
    )

    let pendingActions = try await service.pendingActions(session: session)
    XCTAssertTrue(pendingActions.isEmpty)
  }

  func testProviderSyncRemovesSupersededMailboxStateAction() async throws {
    let store = InMemoryPendingProviderActionStore()
    let service = PendingProviderActionService(store: store)
    let message = pendingActionMessage(
      providerMessageId: "message-restored",
      providerStateIds: ["INBOX"]
    )

    try await service.perform(
      .delete,
      messages: [message],
      connection: connection,
      session: session
    ) { _, _, _ in }
    try await service.perform(
      .restore,
      messages: [message],
      connection: connection,
      session: session
    ) { _, _, _ in }
    let pendingActionCount = try await service.pendingActions(session: session).count
    XCTAssertEqual(pendingActionCount, 2)
    try await service.reconcileProviderSync(
      messages: [
        pendingActionMessage(
          providerMessageId: "message-restored",
          providerStateIds: ["INBOX"]
        )
      ],
      connection: connection,
      session: session
    )

    let pendingActions = try await service.pendingActions(session: session)
    XCTAssertTrue(pendingActions.isEmpty)
  }

  func testEnqueueRejectsMismatchedAccountAndConnection() async throws {
    let service = PendingProviderActionService(store: InMemoryPendingProviderActionStore())
    let message = pendingActionMessage(
      providerMessageId: "message-mismatch",
      providerStateIds: ["INBOX"]
    )
    let otherSession = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-002",
      identityToken: "other-token",
      productAccountId: "product-account-002",
      trustedDeviceId: session.trustedDeviceId
    )

    do {
      try await service.enqueue(
        .archive,
        messages: [message],
        connection: connection,
        session: otherSession
      )
      XCTFail("Expected Product Account mismatch")
    } catch {
      XCTAssertEqual(error as? PendingProviderActionError, .productAccountMismatch)
    }

    let otherConnection = GmailProviderConnectionStatus(
      connectedAt: 1_781_200_000_000,
      emailAddress: "other@example.com",
      lastVerifiedAt: 1_781_200_000_100,
      provider: "gmail",
      providerAccountIdentifier: "gmail-user-002",
      trustedDeviceId: session.trustedDeviceId,
      updatedAt: 1_781_200_000_200
    ).mailboxConnection(productAccountId: session.productAccountId)
    do {
      try await service.enqueue(
        .archive,
        messages: [message],
        connection: otherConnection,
        session: session
      )
      XCTFail("Expected Mailbox Connection mismatch")
    } catch {
      XCTAssertEqual(error as? PendingProviderActionError, .connectionMismatch)
    }
  }

  // swiftlint:disable:next function_body_length
  func testRetryTasksRemainIsolatedAcrossProductAccounts() async throws {
    let store = InMemoryPendingProviderActionStore()
    let service = PendingProviderActionService(
      retryDelayNanoseconds: { _ in 10_000_000 },
      store: store
    )
    let otherSession = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-002",
      identityToken: "other-token",
      productAccountId: "product-account-002",
      trustedDeviceId: session.trustedDeviceId
    )
    let otherConnection = GmailProviderConnectionStatus(
      connectedAt: connection.connectedAt,
      emailAddress: connection.displayName,
      lastVerifiedAt: connection.lastVerifiedAt,
      provider: connection.providerId.rawValue,
      providerAccountIdentifier: connection.providerMailboxIdentity.value,
      trustedDeviceId: connection.trustedDeviceId,
      updatedAt: connection.updatedAt
    ).mailboxConnection(productAccountId: otherSession.productAccountId)
    let recorder = PendingProviderActionRecorder()
    try await service.perform(
      .archive,
      messages: [
        pendingActionMessage(
          providerMessageId: "message-first-account", providerStateIds: ["INBOX"])
      ],
      connection: connection,
      session: session
    ) { _, _, _ in
      throw URLError(.notConnectedToInternet)
    }
    let otherMessage = MailboxMessageMetadata(
      categoryId: nil,
      connectionId: otherConnection.id,
      from: "sender@example.com",
      isHistorical: false,
      providerInternalDateMilliseconds: 1_781_200_000_000,
      providerMessageId: "message-second-account",
      providerStateIds: ["INBOX"],
      providerThreadId: "thread-second-account",
      recipientHeaders: ["reader@example.com"],
      replyTo: nil,
      rfcMessageId: "<message-second-account@example.com>",
      snippet: "Message",
      subject: "Subject"
    )
    try await service.perform(
      .markRead,
      messages: [otherMessage],
      connection: otherConnection,
      session: otherSession
    ) { action, _, messageIds in
      let count = await recorder.recordAndCount(action: action, messageIds: messageIds)
      if count == 1 {
        throw URLError(.timedOut)
      }
    }

    try await service.clear(session: session)
    await service.waitForScheduledRetries(connection: otherConnection, session: otherSession)

    let otherActions = try store.load(productAccountId: otherSession.productAccountId)
    let retryCallCount = await recorder.calls.count
    XCTAssertEqual(otherActions.first?.state, .providerConfirmed)
    XCTAssertEqual(retryCallCount, 2)
  }

  func testCancellationLeavesActionPendingForResume() async throws {
    let service = PendingProviderActionService(
      retryDelayNanoseconds: { _ in 60_000_000_000 },
      store: InMemoryPendingProviderActionStore()
    )
    let message = pendingActionMessage(
      providerMessageId: "message-cancelled",
      providerStateIds: ["INBOX"]
    )

    do {
      try await service.perform(
        .archive,
        messages: [message],
        connection: connection,
        session: session
      ) { _, _, _ in
        throw CancellationError()
      }
      XCTFail("Expected cancellation")
    } catch is CancellationError {
    }

    var actionState = try await service.pendingActions(session: session).first?.state
    XCTAssertEqual(actionState, .pending)
    try await service.resume(
      connection: connection,
      session: session
    ) { _, _, _ in }
    actionState = try await service.pendingActions(session: session).first?.state
    XCTAssertEqual(actionState, .providerConfirmed)
  }

  func testURLSessionCancellationLeavesActionPendingForResume() async throws {
    let service = PendingProviderActionService(
      retryDelayNanoseconds: { _ in 60_000_000_000 },
      store: InMemoryPendingProviderActionStore()
    )
    let message = pendingActionMessage(
      providerMessageId: "message-urlsession-cancelled",
      providerStateIds: ["INBOX"]
    )

    do {
      try await service.perform(
        .archive,
        messages: [message],
        connection: connection,
        session: session
      ) { _, _, _ in
        throw URLError(.cancelled)
      }
      XCTFail("Expected cancellation")
    } catch is CancellationError {
    }

    var actionState = try await service.pendingActions(session: session).first?.state
    XCTAssertEqual(actionState, .pending)
    try await service.resume(
      connection: connection,
      session: session
    ) { _, _, _ in }
    actionState = try await service.pendingActions(session: session).first?.state
    XCTAssertEqual(actionState, .providerConfirmed)
  }

  // swiftlint:disable:next function_body_length
  func testConnectionsProcessIndependently() async throws {
    let store = InMemoryPendingProviderActionStore()
    let service = PendingProviderActionService(
      retryDelayNanoseconds: { _ in 60_000_000_000 },
      store: store
    )
    let otherConnection = GmailProviderConnectionStatus(
      connectedAt: 1_781_200_000_000,
      emailAddress: "other@example.com",
      lastVerifiedAt: 1_781_200_000_100,
      provider: "gmail",
      providerAccountIdentifier: "gmail-user-002",
      trustedDeviceId: "trusted-device-001",
      updatedAt: 1_781_200_000_200
    ).mailboxConnection(productAccountId: session.productAccountId)

    let gate = PendingProviderActionGate()
    async let firstAction: Void = service.perform(
      .archive,
      messages: [
        pendingActionMessage(providerMessageId: "message-001", providerStateIds: ["INBOX"])
      ],
      connection: connection,
      session: session
    ) { _, _, _ in
      await gate.block()
    }
    await gate.waitUntilBlocked()
    let otherMessage = MailboxMessageMetadata(
      categoryId: nil,
      connectionId: otherConnection.id,
      from: "sender@example.com",
      isHistorical: false,
      providerInternalDateMilliseconds: 1_781_200_000_000,
      providerMessageId: "message-002",
      providerStateIds: ["INBOX"],
      providerThreadId: "thread-message-002",
      recipientHeaders: ["other@example.com"],
      replyTo: nil,
      rfcMessageId: "<message-002@example.com>",
      snippet: "Message",
      subject: "Subject"
    )
    try await service.perform(
      .markRead,
      messages: [otherMessage],
      connection: otherConnection,
      session: session
    ) { _, _, _ in }
    await gate.release()
    try await firstAction

    let actions = try await service.pendingActions(session: session)
    XCTAssertEqual(
      actions.first { $0.connectionId == connection.id.rawValue }?.state,
      .providerConfirmed
    )
    XCTAssertEqual(
      actions.first { $0.connectionId == otherConnection.id.rawValue }?.state,
      .providerConfirmed
    )
  }

  private func pendingActionMessage(
    providerMessageId: String,
    providerStateIds: [String]
  ) -> MailboxMessageMetadata {
    MailboxMessageMetadata(
      categoryId: nil,
      connectionId: connection.id,
      from: "sender@example.com",
      isHistorical: false,
      providerInternalDateMilliseconds: 1_781_200_000_000,
      providerMessageId: providerMessageId,
      providerStateIds: providerStateIds,
      providerThreadId: "thread-\(providerMessageId)",
      recipientHeaders: ["reader@example.com"],
      replyTo: nil,
      rfcMessageId: "<\(providerMessageId)@example.com>",
      snippet: "Message",
      subject: "Subject"
    )
  }
}

private enum PendingProviderActionTestError: Error {
  case rejected
}

private actor PendingProviderActionGate {
  private var isBlocked = false
  private var releaseContinuation: CheckedContinuation<Void, Never>?
  private var startedContinuation: CheckedContinuation<Void, Never>?

  func block() async {
    isBlocked = true
    startedContinuation?.resume()
    startedContinuation = nil
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
  }

  func waitUntilBlocked() async {
    guard !isBlocked else { return }
    await withCheckedContinuation { continuation in
      startedContinuation = continuation
    }
  }

  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}

private actor PendingProviderActionRecorder {
  struct Call {
    let action: ProviderMailAction
    let messageIds: [String]
  }

  private(set) var calls: [Call] = []

  func record(action: ProviderMailAction, messageIds: [String]) {
    calls.append(Call(action: action, messageIds: messageIds))
  }

  func recordAndCount(action: ProviderMailAction, messageIds: [String]) -> Int {
    record(action: action, messageIds: messageIds)
    return calls.count
  }
}

private final class InMemoryPendingProviderActionStore: PendingProviderActionPersisting {
  private var actions: [PendingProviderAction] = []

  func load(productAccountId: String) throws -> [PendingProviderAction] {
    actions.filter { $0.productAccountId == productAccountId }
  }

  func save(
    _ actions: [PendingProviderAction],
    productAccountId: String
  ) throws {
    self.actions.removeAll { $0.productAccountId == productAccountId }
    self.actions += actions
  }
}
