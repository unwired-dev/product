import Foundation
import Testing

@testable import unwired_mail

// swiftlint:disable file_length type_body_length

@MainActor
@Suite(.serialized)
final class PendingProviderActionServiceTests {
  private let connection = GmailProviderConnectionStatus(
    connectedAt: 1_781_200_000_000,
    emailAddress: "reader@example.com",
    lastVerifiedAt: 1_781_200_000_100,
    provider: "gmail",
    providerAccountIdentifier: "gmail-user-001",
    trustedDeviceId: "trusted-device-001",
    updatedAt: 1_781_200_000_200
  ).mailboxConnection(productAccountId: "product-account-001", authorizationState: .authorized)

  private let session = ProductAccountSessionSnapshot(
    appleUserIdentifier: "apple-user-001",
    identityToken: "product-token",
    productAccountId: "product-account-001",
    trustedDeviceId: "trusted-device-001"
  )

  @Test
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
    ) { _, _, _, _ in
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

    #expect(try store.load(productAccountId: session.productAccountId).count == 1)
    #expect(projected.messages.isEmpty)
  }

  @Test
  func testTransientEWSOAuthFailureRemainsPendingForRetry() async throws {
    let store = InMemoryPendingProviderActionStore()
    let service = PendingProviderActionService(
      retryDelayNanoseconds: { _ in 60_000_000_000 },
      store: store
    )
    let message = pendingActionMessage(
      providerMessageId: "message-001",
      providerStateIds: ["INBOX"],
      connectionId: ewsConnection.id
    )

    try await service.perform(
      .archive,
      messages: [message],
      connection: ewsConnection,
      session: session
    ) { _, _, _, _ in
      throw EWSOAuthError.tokenExchangeFailed(status: 503)
    }

    let action = try requireValue(store.load(productAccountId: session.productAccountId).first)
    #expect(action.state == .pending)
    #expect(action.attemptCount == 1)
  }

  @Test
  func testOptimisticProjectionPreservesHistoricalBackfillResumeAvailability() async throws {
    let store = InMemoryPendingProviderActionStore()
    let service = PendingProviderActionService(store: store)
    let message = pendingActionMessage(
      providerMessageId: "message-001",
      providerStateIds: ["INBOX", "UNREAD"]
    )

    try await service.perform(
      .markRead,
      messages: [message],
      connection: connection,
      session: session
    ) { _, _, _, _ in
      throw URLError(.notConnectedToInternet)
    }

    let projected = try await service.project(
      MailboxMetadataSyncResult(
        hasUnlistedNewMessages: false,
        messages: [message],
        newMessageIds: nil,
        providerCursorIsExpired: false,
        threads: MailboxThread.group([message]),
        historicalMetadataBackfillCanResume: false
      ),
      connection: connection,
      session: session
    )

    #expect(!(projected.historicalMetadataBackfillCanResume))
  }

  @Test
  func testFailureLookupDoesNotCoverPendingSelectedActions() async throws {
    let store = InMemoryPendingProviderActionStore()
    let service = PendingProviderActionService(store: store)
    let message = pendingActionMessage(
      providerMessageId: "message-pending",
      providerStateIds: ["INBOX"]
    )

    try await service.perform(
      .archive,
      messages: [message],
      connection: connection,
      session: session
    ) { _, _, _, _ in
      throw URLError(.notConnectedToInternet)
    }

    let details = try await service.failureDetails(
      .archive,
      messageIds: [message.providerMessageId],
      connection: connection,
      session: session
    )
    let selectedActionIds = try Set(
      store.load(productAccountId: session.productAccountId).map(\.id)
    )
    let lookup = try await service.failureLookup(
      .archive,
      selectedActionIds: selectedActionIds,
      messageIds: [message.providerMessageId],
      connection: connection,
      session: session
    )
    let missingLookup = try await service.failureLookup(
      .archive,
      selectedActionIds: selectedActionIds,
      messageIds: ["message-missing"],
      connection: connection,
      session: session
    )
    #expect(details == [])
    #expect(!(lookup.coversSelectedMessageIds))
    #expect(lookup.details == [])
    #expect(lookup.matchedPendingActionIds == selectedActionIds)
    #expect(!(missingLookup.coversSelectedMessageIds))
    #expect(missingLookup.details == [])
    #expect(missingLookup.matchedPendingActionIds == [])
  }

  @Test
  func testFailureLookupRetainsSelectedSuccessAfterReconciliation() async throws {
    let store = InMemoryPendingProviderActionStore()
    let service = PendingProviderActionService(
      failureDisposition: { _ in .permanent },
      store: store
    )
    let failedMessage = pendingActionMessage(
      providerMessageId: "older-failure",
      providerStateIds: ["INBOX"]
    )
    let selectedMessage = pendingActionMessage(
      providerMessageId: "selected-success",
      providerStateIds: ["INBOX"]
    )
    do {
      try await service.perform(
        .archive,
        messages: [failedMessage],
        connection: connection,
        session: session
      ) { _, _, _, _ in
        throw PendingProviderActionTestError.rejected
      }
      Issue.record("Expected the older action to fail")
    } catch is PendingProviderActionTestError {}
    let selection = try await service.enqueue(
      .archive,
      messages: [selectedMessage],
      connection: connection,
      session: session
    )
    try await service.resume(connection: connection, session: session) { _, _, _, _ in }
    try await service.reconcileProviderSync(
      messages: [selectedMessage],
      connection: connection,
      session: session,
      isConfirmed: { _, _, messageIds in messageIds == [selectedMessage.providerMessageId] }
    )

    let lookup = try await service.failureLookup(
      .archive,
      selectedActionIds: selection.pendingActionIds,
      messageIds: [selectedMessage.providerMessageId],
      connection: connection,
      session: session
    )

    #expect(lookup.coversSelectedMessageIds)
    #expect(lookup.details == [])
    #expect(lookup.matchedPendingActionIds == selection.pendingActionIds)
  }

  @Test
  func testFailureLookupRetainsActiveSelectionBeyondEvidenceLimit() async throws {
    let store = InMemoryPendingProviderActionStore()
    let service = PendingProviderActionService(store: store)
    let messages = (0...1_000).map {
      pendingActionMessage(providerMessageId: "selected-\($0)", providerStateIds: ["INBOX"])
    }
    let selection = try await service.enqueue(
      .archive,
      messages: messages,
      connection: connection,
      session: session
    )
    var actions = try store.load(productAccountId: session.productAccountId)
    for index in actions.indices {
      actions[index].state = .providerConfirmed
    }
    try store.save(actions, productAccountId: session.productAccountId)
    try await service.reconcileProviderSync(
      messages: messages,
      connection: connection,
      session: session,
      isConfirmed: { _, _, _ in true }
    )

    let lookup = try await service.failureLookup(
      .archive,
      selectedActionIds: selection.pendingActionIds,
      messageIds: Set(messages.map(\.providerMessageId)),
      connection: connection,
      session: session
    )

    #expect(lookup.coversSelectedMessageIds)
    #expect(lookup.details == [])
    #expect(lookup.matchedPendingActionIds == selection.pendingActionIds)
  }

  @Test
  func testReleasedSelectionDoesNotBypassEvidenceLimit() async throws {
    let store = InMemoryPendingProviderActionStore()
    let service = PendingProviderActionService(store: store)
    let releasedMessage = pendingActionMessage(
      providerMessageId: "released-selection",
      providerStateIds: ["INBOX"]
    )
    let releasedSelection = try await service.enqueue(
      .archive,
      messages: [releasedMessage],
      connection: connection,
      session: session
    )
    await service.releaseSelection(releasedSelection)
    let activeMessages = (0..<1_000).map {
      pendingActionMessage(providerMessageId: "active-\($0)", providerStateIds: ["INBOX"])
    }
    _ = try await service.enqueue(
      .archive,
      messages: activeMessages,
      connection: connection,
      session: session
    )
    var actions = try store.load(productAccountId: session.productAccountId)
    for index in actions.indices {
      actions[index].state = .providerConfirmed
    }
    try store.save(actions, productAccountId: session.productAccountId)
    try await service.reconcileProviderSync(
      messages: [releasedMessage] + activeMessages,
      connection: connection,
      session: session,
      isConfirmed: { _, _, _ in true }
    )

    let lookup = try await service.failureLookup(
      .archive,
      selectedActionIds: releasedSelection.pendingActionIds,
      messageIds: [releasedMessage.providerMessageId],
      connection: connection,
      session: session
    )

    #expect(!(lookup.coversSelectedMessageIds))
    #expect(lookup.details == [])
    #expect(lookup.matchedPendingActionIds == [])
  }

  @Test
  func testClearReleasesReconciledActiveSelection() async throws {
    let store = InMemoryPendingProviderActionStore()
    let service = PendingProviderActionService(store: store)
    let message = pendingActionMessage(
      providerMessageId: "cleared-selection",
      providerStateIds: ["INBOX"]
    )
    _ = try await service.enqueue(
      .archive,
      messages: [message],
      connection: connection,
      session: session
    )
    var actions = try store.load(productAccountId: session.productAccountId)
    actions[0].state = .providerConfirmed
    try store.save(actions, productAccountId: session.productAccountId)
    try await service.reconcileProviderSync(
      messages: [message],
      connection: connection,
      session: session,
      isConfirmed: { _, _, _ in true }
    )
    let activeSelectionCount = await service.activeSelectionActionCountForTesting()
    #expect(activeSelectionCount == 1)

    try await service.clear(connection: connection, session: session)

    let clearedSelectionCount = await service.activeSelectionActionCountForTesting()
    #expect(clearedSelectionCount == 0)
  }

  @Test
  func testFailureLookupReportsContradictedSelectedAction() async throws {
    let store = InMemoryPendingProviderActionStore()
    let service = PendingProviderActionService(store: store)
    let message = pendingActionMessage(
      providerMessageId: "selected-contradiction",
      providerStateIds: ["INBOX"]
    )
    let selection = try await service.enqueue(
      .archive,
      messages: [message],
      connection: connection,
      session: session
    )
    var actions = try store.load(productAccountId: session.productAccountId)
    actions[0].state = .providerConfirmed
    try store.save(actions, productAccountId: session.productAccountId)
    try await service.reconcileProviderSync(
      messages: [message],
      connection: connection,
      session: session,
      isConfirmed: { _, _, _ in false }
    )

    let lookup = try await service.failureLookup(
      .archive,
      selectedActionIds: selection.pendingActionIds,
      messageIds: [message.providerMessageId],
      connection: connection,
      session: session
    )

    #expect(lookup.coversSelectedMessageIds)
    #expect(lookup.details.map(\.description) == ["The provider did not confirm this action."])
    #expect(lookup.matchedPendingActionIds == selection.pendingActionIds)
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testFailureLookupRetainsEvidenceUntilSelectionIsCovered() async throws {
    let store = InMemoryPendingProviderActionStore()
    let service = PendingProviderActionService(store: store)
    let reconciledMessage = pendingActionMessage(
      providerMessageId: "reconciled-success",
      providerStateIds: ["INBOX"]
    )
    let pendingMessage = pendingActionMessage(
      providerMessageId: "pending-success",
      providerStateIds: ["INBOX"]
    )
    let selection = try await service.enqueue(
      .archive,
      messages: [reconciledMessage, pendingMessage],
      connection: connection,
      session: session
    )
    var actions = try store.load(productAccountId: session.productAccountId)
    let reconciledIndex = try requireValue(
      actions.firstIndex { $0.messageIds == [reconciledMessage.providerMessageId] })
    actions[reconciledIndex].state = .providerConfirmed
    try store.save(actions, productAccountId: session.productAccountId)
    try await service.reconcileProviderSync(
      messages: [reconciledMessage, pendingMessage],
      connection: connection,
      session: session,
      isConfirmed: { _, _, messageIds in
        messageIds == [reconciledMessage.providerMessageId]
      }
    )

    let messageIds = Set([reconciledMessage.providerMessageId, pendingMessage.providerMessageId])
    let partialLookup = try await service.failureLookup(
      .archive,
      selectedActionIds: selection.pendingActionIds,
      messageIds: messageIds,
      connection: connection,
      session: session
    )
    #expect(!(partialLookup.coversSelectedMessageIds))

    actions = try store.load(productAccountId: session.productAccountId)
    let pendingIndex = try requireValue(
      actions.firstIndex { $0.messageIds == [pendingMessage.providerMessageId] })
    actions[pendingIndex].state = .providerConfirmed
    try store.save(actions, productAccountId: session.productAccountId)
    let completeLookup = try await service.failureLookup(
      .archive,
      selectedActionIds: selection.pendingActionIds,
      messageIds: messageIds,
      connection: connection,
      session: session
    )
    #expect(completeLookup.coversSelectedMessageIds)
    #expect(completeLookup.details == [])
    #expect(completeLookup.matchedPendingActionIds == selection.pendingActionIds)
  }

  @Test
  func testFailureLookupRetainsReconciledUserActionRequiredSuccess() async throws {
    let store = InMemoryPendingProviderActionStore()
    let service = PendingProviderActionService(store: store)
    let message = pendingActionMessage(
      providerMessageId: "reconciled-blocked-success",
      providerStateIds: ["INBOX"]
    )
    let selection = try await service.enqueue(
      .archive,
      messages: [message],
      connection: connection,
      session: session
    )
    var actions = try store.load(productAccountId: session.productAccountId)
    actions[0].state = .userActionRequired
    try store.save(actions, productAccountId: session.productAccountId)
    try await service.reconcileProviderSync(
      messages: [message],
      connection: connection,
      session: session,
      isConfirmed: { _, _, _ in true }
    )

    let lookup = try await service.failureLookup(
      .archive,
      selectedActionIds: selection.pendingActionIds,
      messageIds: [message.providerMessageId],
      connection: connection,
      session: session
    )
    #expect(lookup.coversSelectedMessageIds)
    #expect(lookup.details == [])
    #expect(lookup.matchedPendingActionIds == selection.pendingActionIds)
  }

  @Test
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
    let offline: PendingProviderActionPerformer = { _, _, _, _ in
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
    ) { action, _, _, messageIds in
      await recorder.record(action: action, messageIds: messageIds)
    }

    let calls = await recorder.calls
    #expect(calls.map(\.action) == [.archive, .markRead])
    #expect(calls.map(\.messageIds) == [["message-001"], ["message-002"]])
    #expect(
      try store.load(productAccountId: session.productAccountId).map(\.state) == [
        .providerConfirmed, .providerConfirmed,
      ])
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testProviderMailboxMovePersistsSourceAndReplaysAfterRestart() async throws {
    let store = InMemoryPendingProviderActionStore()
    let firstService = PendingProviderActionService(
      retryDelayNanoseconds: { _ in 60_000_000_000 },
      store: store
    )
    let message = pendingActionMessage(
      providerMessageId: "message-provider-label-move",
      providerStateIds: ["INBOX", "Label_source", "Label_unrelated"]
    )

    try await firstService.perform(
      .move,
      sourceProviderMailboxId: "Label_source",
      targetProviderMailboxId: "Label_destination",
      messages: [message],
      connection: connection,
      session: session
    ) { _, _, _, _ in
      throw URLError(.notConnectedToInternet)
    }

    let persistedAction = try requireValue(
      store.load(productAccountId: session.productAccountId).first)
    #expect(persistedAction.sourceProviderMailboxId == "Label_source")
    let projected = try await firstService.project(
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
    #expect(
      Set(try requireValue(projected.messages.first?.providerStateIds)) == [
        "INBOX", "Label_destination", "Label_unrelated",
      ])

    let recorder = PendingProviderActionRecorder()
    let restartedService = PendingProviderActionService(store: store)
    try await restartedService.resume(
      connection: connection,
      session: session
    ) { action, sourceProviderMailboxId, targetProviderMailboxId, messageIds in
      await recorder.record(
        action: action,
        sourceProviderMailboxId: sourceProviderMailboxId,
        targetProviderMailboxId: targetProviderMailboxId,
        messageIds: messageIds
      )
    }

    let calls = await recorder.calls
    let call = try requireValue(calls.first)
    #expect(call.action == .move)
    #expect(call.sourceProviderMailboxId == "Label_source")
    #expect(call.targetProviderMailboxId == "Label_destination")
    #expect(call.messageIds == ["message-provider-label-move"])
  }

  @Test
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
    ) { action, _, _, messageIds in
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
    ) { action, _, _, messageIds in
      await recorder.record(action: action, messageIds: messageIds)
    }

    let callCount = await recorder.calls.count
    #expect(callCount == 1)
    #expect(try store.load(productAccountId: session.productAccountId).isEmpty)
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
    #expect(providerConflict.messages == [message])
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testFullCapabilityActionsProjectProviderState() async throws {
    // swiftlint:disable:next large_tuple
    let cases: [(ProviderMailAction, String?, [String], Set<String>)] = [
      (.markRead, nil, ["INBOX", "UNREAD"], ["INBOX"]),
      (.markUnread, nil, ["INBOX"], ["INBOX", "UNREAD"]),
      (.archive, nil, ["INBOX"], []),
      (.archive, nil, ["ews-folder:source"], []),
      (.move, "Label_projects", ["INBOX"], ["Label_projects"]),
      (
        .move, "graph-folder:destination", ["graph-folder:source", "UNREAD"],
        ["graph-folder:destination", "UNREAD"]
      ),
      (.move, "ews-folder:destination", ["ews-folder:source"], ["ews-folder:destination"]),
      (.delete, nil, ["INBOX"], ["TRASH"]),
      (.restore, nil, ["TRASH"], ["INBOX"]),
      (.restore, nil, ["ews-folder:source", "TRASH"], ["INBOX"]),
      (.spam, nil, ["graph-folder:source", "INBOX"], ["SPAM"]),
      (.spam, nil, ["ews-folder:source", "INBOX"], ["SPAM"]),
      (.notSpam, nil, ["SPAM"], ["INBOX"]),
      (.notSpam, nil, ["ews-folder:source", "SPAM"], ["INBOX"]),
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
      ) { _, _, _, _ in
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

      #expect(Set(projected.messages[0].providerStateIds ?? []) == testCase.3)
    }
  }

  @Test
  func testEWSArchiveProjectionMarksOnlineArchiveHierarchy() async throws {
    let store = InMemoryPendingProviderActionStore()
    let service = PendingProviderActionService(
      retryDelayNanoseconds: { _ in 60_000_000_000 },
      store: store
    )
    let message = pendingActionMessage(
      providerMessageId: "message-ews-archive",
      providerStateIds: ["INBOX"],
      connectionId: ewsConnection.id
    )
    try await service.perform(
      .archive,
      messages: [message],
      connection: ewsConnection,
      session: session
    ) { _, _, _, _ in
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
      connection: ewsConnection,
      session: session
    )

    #expect(
      Set(try requireValue(projected.messages.first?.providerStateIds)) == [
        "ARCHIVE", EWSProviderMessage.archiveHierarchyStateId,
      ])
  }

  @Test
  func testEWSDeleteProjectionPreservesOnlineArchiveHierarchy() async throws {
    let store = InMemoryPendingProviderActionStore()
    let service = PendingProviderActionService(
      retryDelayNanoseconds: { _ in 60_000_000_000 },
      store: store
    )
    let message = pendingActionMessage(
      providerMessageId: "message-ews-archive-delete",
      providerStateIds: [
        EWSProviderMessage.archiveHierarchyStateId,
        EWSProviderMessage.customFolderStateId("archive-folder"),
      ],
      connectionId: ewsConnection.id
    )
    try await service.perform(
      .delete,
      messages: [message],
      connection: ewsConnection,
      session: session
    ) { _, _, _, _ in
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
      connection: ewsConnection,
      session: session
    )

    #expect(
      Set(try requireValue(projected.messages.first?.providerStateIds)) == [
        "TRASH", EWSProviderMessage.archiveHierarchyStateId,
      ])
  }

  @Test
  func testEWSMoveProjectionRecomputesInheritedDestinationRole() async throws {
    // swiftlint:disable:next large_tuple
    let cases: [(sourceStates: [String], targetStates: Set<String>, expected: Set<String>)] = [
      (
        ["SPAM", EWSProviderMessage.customFolderStateId("junk-projects"), "UNREAD"],
        [],
        [EWSProviderMessage.customFolderStateId("projects"), "UNREAD"]
      ),
      (
        [EWSProviderMessage.customFolderStateId("projects"), "UNREAD"],
        ["TRASH"],
        ["TRASH", EWSProviderMessage.customFolderStateId("deleted-projects"), "UNREAD"]
      ),
    ]

    for (index, testCase) in cases.enumerated() {
      let store = InMemoryPendingProviderActionStore()
      let service = PendingProviderActionService(store: store)
      let message = pendingActionMessage(
        providerMessageId: "message-ews-move-\(index)",
        providerStateIds: testCase.sourceStates,
        connectionId: ewsConnection.id
      )
      let targetFolderState =
        index == 0
        ? EWSProviderMessage.customFolderStateId("projects")
        : EWSProviderMessage.customFolderStateId("deleted-projects")
      try await service.enqueue(
        .move,
        targetProviderMailboxId: targetFolderState,
        targetProviderStateIds: testCase.targetStates,
        messages: [message],
        connection: ewsConnection,
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
        collection: .allObserved,
        connection: ewsConnection,
        session: session
      )

      #expect(
        Set(try requireValue(projected.messages.first?.providerStateIds)) == testCase.expected)
    }
  }

  @Test
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
    let offline: PendingProviderActionPerformer = { _, _, _, _ in
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
      try await service.resume(
        connection: connection,
        session: session
      ) { action, _, _, messageIds in
        await recorder.record(action: action, messageIds: messageIds)
        if action == .archive {
          throw PendingProviderActionTestError.rejected
        }
      }
      Issue.record("Expected permanent rejection")
    } catch let error as PendingProviderActionTestError {
      guard case .rejected = error else {
        Issue.record("Expected provider rejection")
        return
      }
    }

    let calls = await recorder.calls
    #expect(calls.map(\.action) == [.archive, .markRead])
    #expect(
      try store.load(productAccountId: session.productAccountId).map(\.state) == [
        .failed, .providerConfirmed,
      ])
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
    #expect(
      Set(projected.messages.first { $0.id == archivedMessage.id }?.providerStateIds ?? []) == [
        "INBOX"
      ])
    #expect(
      Set(projected.messages.first { $0.id == readMessage.id }?.providerStateIds ?? []) == ["INBOX"]
    )
  }

  @Test
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
    ) { action, _, _, messageIds in
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
    #expect(callCount == 2)
    #expect(actionState == .providerConfirmed)
  }

  @Test
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
    ) { action, _, _, messageIds in
      await recorder.record(action: action, messageIds: messageIds)
      throw URLError(.timedOut)
    }
    try await service.resume(
      connection: connection,
      session: session
    ) { action, _, _, messageIds in
      await recorder.record(action: action, messageIds: messageIds)
    }

    let calls = await recorder.calls
    #expect(calls.count == 1)
    try await service.clear(session: session)
  }

  @Test
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
      ) { action, _, _, messageIds in
        await recorder.record(action: action, messageIds: messageIds)
        if messageIds == ["message-second"] {
          throw PendingProviderActionTestError.rejected
        }
      }
      Issue.record("Expected the second provider action to fail")
    } catch let error as PendingProviderActionTestError {
      guard case .rejected = error else {
        Issue.record("Expected provider rejection")
        return
      }
    }

    let actions = try store.load(productAccountId: session.productAccountId)
    let calls = await recorder.calls
    #expect(calls.map(\.messageIds) == [["message-first"], ["message-second"]])
    #expect(actions.map(\.messageIds) == [["message-first"], ["message-second"]])
    #expect(actions.map(\.state) == [.providerConfirmed, .failed])
  }

  @Test
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
        ) { _, _, _, _ in
          throw credentialError
        }
        Issue.record("Expected credential failure")
      } catch let error as PendingProviderActionError {
        guard case .retryLimitReached = error else {
          Issue.record("Expected user-action-required failure")
          return
        }
      }
      #expect(
        try store.load(productAccountId: session.productAccountId).first?.state
          == .userActionRequired)
    }
  }

  @Test
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
      ) { action, _, _, messageIds in
        await recorder.record(action: action, messageIds: messageIds)
        throw URLError(.timedOut)
      }
    } catch let error as PendingProviderActionError {
      guard case .retryLimitReached = error else {
        Issue.record("Expected retry-limit failure")
        return
      }
    } catch {
      Issue.record("Expected timeout, got \(error)")
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
      ) { action, _, _, messageIds in
        await recorder.record(action: action, messageIds: messageIds)
      }
      Issue.record("Expected the terminal action to block ordinary resume")
    } catch let error as PendingProviderActionError {
      guard case .retryLimitReached = error else {
        Issue.record("Expected retry-limit failure")
        return
      }
    }
    var calls = await recorder.calls
    #expect(calls.count == 1)

    try await service.discardBlockedAction(
      connection: connection,
      session: session
    ) { action, _, _, messageIds in
      await recorder.record(action: action, messageIds: messageIds)
    }
    calls = await recorder.calls
    #expect(calls.map(\.action) == [.archive, .markRead])
    #expect(
      try store.load(productAccountId: session.productAccountId).map(\.state) == [
        .providerConfirmed
      ])
  }

  @Test
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
      ) { _, _, _, _ in
        throw GmailMessageMetadataSyncError.missingLocalGmailTokens
      }
    } catch let error as PendingProviderActionError {
      guard case .retryLimitReached = error else {
        Issue.record("Expected retry-limit failure")
        return
      }
    } catch {
      Issue.record("Expected missing-local-token failure, got \(error)")
    }

    try await service.retryBlockedAction(
      connection: connection,
      session: session
    ) { _, _, _, _ in }

    #expect(
      try store.load(productAccountId: session.productAccountId).first?.state == .providerConfirmed)
  }

  @Test
  func testResumeStopsBeforeProviderDispatchWhenTrustRevalidationFails() async throws {
    let store = InMemoryPendingProviderActionStore()
    let service = PendingProviderActionService(store: store)
    let message = pendingActionMessage(
      providerMessageId: "message-revoked-before-resume",
      providerStateIds: ["INBOX"]
    )
    _ = try await service.enqueue(
      .archive,
      messages: [message],
      connection: connection,
      session: session
    )

    do {
      try await service.resume(
        connection: connection,
        session: session,
        revalidateProviderAccess: { false },
        provider: { _, _, _, _ in
          Issue.record("Provider access must not occur after revocation")
        }
      )
      Issue.record("Expected cancellation")
    } catch is CancellationError {
    }

    let pendingAction = try requireValue(
      store.load(productAccountId: session.productAccountId).first)
    #expect(pendingAction.attemptCount == 0)
    #expect(pendingAction.state == .pending)
  }

  @Test
  func testScheduledRetryRevalidatesAgainBeforeProviderDispatch() async throws {
    let store = InMemoryPendingProviderActionStore()
    let service = PendingProviderActionService(
      retryDelayNanoseconds: { _ in 1_000_000 },
      store: store
    )
    let message = pendingActionMessage(
      providerMessageId: "message-revoked-before-automatic-retry",
      providerStateIds: ["INBOX"]
    )
    let providerRecorder = PendingProviderActionRecorder()
    let revalidationRecorder = ProviderActionRevalidationRecorder(
      results: [true, false]
    )
    _ = try await service.enqueue(
      .archive,
      messages: [message],
      connection: connection,
      session: session
    )

    try await service.resume(
      connection: connection,
      session: session,
      revalidateProviderAccess: {
        await revalidationRecorder.revalidate()
      },
      provider: { action, _, _, messageIds in
        await providerRecorder.record(action: action, messageIds: messageIds)
        throw URLError(.timedOut)
      }
    )
    await service.waitForScheduledRetries(connection: connection, session: session)

    let revalidationCount = await revalidationRecorder.callCount
    let providerCallCount = await providerRecorder.calls.count
    #expect(revalidationCount == 2)
    #expect(providerCallCount == 1)
    let pendingAction = try requireValue(
      store.load(productAccountId: session.productAccountId).first)
    #expect(pendingAction.attemptCount == 1)
    #expect(pendingAction.state == .pending)
  }

  @Test
  func testExplicitRetryLeavesBlockedActionUntouchedWhenTrustRevalidationFails() async throws {
    let store = InMemoryPendingProviderActionStore()
    let service = PendingProviderActionService(store: store)
    let message = pendingActionMessage(
      providerMessageId: "message-revoked",
      providerStateIds: ["INBOX"]
    )
    do {
      try await service.perform(
        .archive,
        messages: [message],
        connection: connection,
        session: session
      ) { _, _, _, _ in
        throw GmailMessageMetadataSyncError.missingLocalGmailTokens
      }
    } catch let error as PendingProviderActionError {
      guard case .retryLimitReached = error else {
        Issue.record("Expected retry-limit failure")
        return
      }
    }

    do {
      try await service.retryBlockedAction(
        connection: connection,
        session: session,
        revalidateProviderAccess: { false },
        provider: { _, _, _, _ in
          Issue.record("Provider access must not occur after revocation")
        }
      )
      Issue.record("Expected cancellation")
    } catch is CancellationError {
    }

    #expect(
      try store.load(productAccountId: session.productAccountId).first?.state == .userActionRequired
    )
  }

  @Test
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
    let unavailable: PendingProviderActionPerformer = { action, _, _, messageIds in
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
    #expect(actionState == .userActionRequired)
    #expect(failureDescription != nil)
    #expect(projected.messages.isEmpty)

    do {
      try await service.resume(
        connection: connection,
        session: session,
        provider: unavailable
      )
      Issue.record("Expected retry-limit failure")
    } catch let error as PendingProviderActionError {
      guard case .retryLimitReached = error else {
        Issue.record("Expected retry-limit failure")
        return
      }
    }
  }

  @Test
  func testGraphReadStateServerFailureRetriesAutomatically() async throws {
    let recorder = PendingProviderActionRecorder()
    let store = InMemoryPendingProviderActionStore()
    let service = PendingProviderActionService(
      maximumAttempts: 2,
      retryDelayNanoseconds: { _ in 1_000_000 },
      store: store
    )
    let message = pendingActionMessage(
      providerMessageId: "message-read-retry",
      providerStateIds: ["INBOX", "UNREAD"]
    )

    try await service.perform(
      .markRead,
      messages: [message],
      connection: connection,
      session: session
    ) { action, _, _, messageIds in
      let count = await recorder.recordAndCount(action: action, messageIds: messageIds)
      if count == 1 {
        throw MicrosoftGraphClientError.requestFailed(500)
      }
    }
    await service.waitForScheduledRetries(connection: connection, session: session)

    let calls = await recorder.calls
    #expect(calls.map(\.action) == [.markRead, .markRead])
    #expect(
      try store.load(productAccountId: session.productAccountId).first?.state == .providerConfirmed)
  }

  @Test
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
      ) { _, _, _, _ in
        throw PendingProviderActionTestError.rejected
      }
    } catch let error as PendingProviderActionTestError {
      guard case .rejected = error else {
        Issue.record("Expected provider rejection")
        return
      }
    } catch {
      Issue.record("Expected provider rejection, got \(error)")
    }

    let backgroundRead = try await service.failureDescription(
      connection: connection,
      session: session
    )
    let foregroundRead = try await service.failureDescription(
      connection: connection,
      session: session
    )
    #expect(backgroundRead == foregroundRead)
    var hasFailedAction = try await service.hasFailedAction(
      connection: connection,
      session: session
    )
    #expect(hasFailedAction)

    try await service.acknowledgeFailures(connection: connection, session: session)
    hasFailedAction = try await service.hasFailedAction(
      connection: connection,
      session: session
    )
    #expect(!(hasFailedAction))
  }

  @Test
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
      ) { _, _, _, _ in
        throw GmailMessageMetadataSyncError.missingLocalGmailTokens
      }
      Issue.record("Expected retry-limit failure")
    } catch let error as PendingProviderActionError {
      guard case .retryLimitReached = error else {
        Issue.record("Expected retry-limit failure")
        return
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
    #expect(actions.isEmpty)
  }

  @Test
  func testProviderSyncKeepsBlockedActionWhenProviderSpecificConfirmationRejectsIt() async throws {
    let store = InMemoryPendingProviderActionStore()
    let service = PendingProviderActionService(store: store)
    let message = pendingActionMessage(
      providerMessageId: "message-blocked-archive",
      providerStateIds: ["SENT"]
    )

    do {
      try await service.perform(
        .archive,
        messages: [message],
        connection: connection,
        session: session
      ) { _, _, _, _ in
        throw GmailMessageMetadataSyncError.missingLocalGmailTokens
      }
      Issue.record("Expected retry-limit failure")
    } catch let error as PendingProviderActionError {
      guard case .retryLimitReached = error else {
        Issue.record("Expected retry-limit failure")
        return
      }
    }

    try await service.reconcileProviderSync(
      messages: [message],
      connection: connection,
      session: session,
      isConfirmed: { _, _, _ in false }
    )

    let actions = try await service.pendingActions(session: session)
    #expect(actions.count == 1)
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testGraphArchiveReconciliationRequiresArchiveState() async throws {
    let store = InMemoryPendingProviderActionStore()
    let service = PendingProviderActionService(
      failureDisposition: { _ in .userActionRequired },
      store: store
    )
    let graphConnection = MailboxConnection(
      authorizationState: .authorized,
      capabilities: .microsoftGraph,
      connectedAt: 1_781_200_000_000,
      displayName: "reader@example.com",
      id: MailboxConnectionId(
        providerMailboxIdentity: StableProviderMailboxIdentity(
          providerId: .microsoftGraph,
          value: "graph-user-001"
        )
      ),
      lastVerifiedAt: 1_781_200_000_100,
      productAccountId: ProductAccountId(session.productAccountId),
      trustedDeviceId: session.trustedDeviceId,
      updatedAt: 1_781_200_000_200
    )
    let message = pendingActionMessage(
      providerMessageId: "message-graph-archive",
      providerStateIds: ["INBOX"],
      connectionId: graphConnection.id
    )
    do {
      try await service.perform(
        .archive,
        messages: [message],
        connection: graphConnection,
        session: session
      ) { _, _, _, _ in
        throw PendingProviderActionTestError.rejected
      }
      Issue.record("Expected ambiguous archive failure")
    } catch let error as PendingProviderActionError {
      guard case .retryLimitReached = error else {
        Issue.record("Expected retry-limit failure")
        return
      }
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
      connection: graphConnection,
      session: session
    )
    #expect(Set(try requireValue(projected.messages.first?.providerStateIds)) == ["ARCHIVE"])

    try await service.reconcileProviderSync(
      messages: [
        pendingActionMessage(
          providerMessageId: message.providerMessageId,
          providerStateIds: []
        )
      ],
      connection: graphConnection,
      session: session
    )
    var actions = try await service.pendingActions(session: session)
    #expect(actions.count == 1)

    try await service.reconcileProviderSync(
      messages: [
        pendingActionMessage(
          providerMessageId: message.providerMessageId,
          providerStateIds: ["ARCHIVE"]
        )
      ],
      connection: graphConnection,
      session: session
    )
    actions = try await service.pendingActions(session: session)
    #expect(actions.isEmpty)
  }

  @Test
  func testNonAuthoritativeSyncKeepsContradictedConfirmedAction() async throws {
    let store = InMemoryPendingProviderActionStore()
    let service = PendingProviderActionService(store: store)
    let message = pendingActionMessage(
      providerMessageId: "message-confirmed-archive",
      providerStateIds: ["INBOX"]
    )
    try await service.perform(
      .archive,
      messages: [message],
      connection: connection,
      session: session
    ) { _, _, _, _ in }

    try await service.reconcileProviderSync(
      messages: [message],
      removesContradictedActions: false,
      connection: connection,
      session: session
    )

    var actions = try await service.pendingActions(session: session)
    #expect(actions.count == 1)
    try await service.reconcileProviderSync(
      messages: [message],
      connection: connection,
      session: session
    )
    actions = try await service.pendingActions(session: session)
    #expect(actions.isEmpty)
  }

  @Test
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
    ) { _, _, _, _ in }
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

    #expect(projected.messages.isEmpty)
  }

  @Test
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
    #expect(initiallyProjected.messages == [message])

    try await service.perform(
      .delete,
      messages: [message],
      connection: connection,
      session: session
    ) { _, _, _, _ in }
    let projected = try await service.project(
      result,
      collection: .providerMailbox("Label_projects"),
      connection: connection,
      session: session
    )

    #expect(projected.messages.isEmpty)
  }

  @Test
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
    ) { _, _, _, _ in }
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
    #expect(pendingActions.isEmpty)
  }

  @Test
  func testOptimisticGraphMoveRemovesThePreviousFolder() async throws {
    let service = PendingProviderActionService(store: InMemoryPendingProviderActionStore())
    let message = pendingActionMessage(
      providerMessageId: "message-graph-move",
      providerStateIds: ["graph-folder:source", "UNREAD"]
    )

    try await service.perform(
      .move,
      targetProviderMailboxId: "graph-folder:destination",
      messages: [message],
      connection: connection,
      session: session
    ) { _, _, _, _ in }
    let projected = try await service.project(
      MailboxMetadataSyncResult(
        hasUnlistedNewMessages: false,
        messages: [message],
        newMessageIds: nil,
        providerCursorIsExpired: false,
        threads: MailboxThread.group([message]),
        hasInitialMailboxAvailability: true,
        historicalMetadataBackfillIsComplete: true
      ),
      collection: .providerMailbox("graph-folder:destination"),
      connection: connection,
      session: session
    )

    #expect(projected.messages.first?.providerStateIds == ["UNREAD", "graph-folder:destination"])
  }

  @Test
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
    ) { _, _, _, _ in }
    try await service.perform(
      .markUnread,
      messages: [message],
      connection: connection,
      session: session
    ) { _, _, _, _ in }
    try await service.reconcileProviderSync(
      messages: [message],
      connection: connection,
      session: session
    )

    let pendingActions = try await service.pendingActions(session: session)
    #expect(pendingActions.isEmpty)
  }

  @Test
  func testFailureLookupRetainsSupersededSelectedActionEvidence() async throws {
    let store = InMemoryPendingProviderActionStore()
    let service = PendingProviderActionService(store: store)
    let message = pendingActionMessage(
      providerMessageId: "message-superseded-selection",
      providerStateIds: ["INBOX", "UNREAD"]
    )
    let selection = try await service.enqueue(
      .markRead,
      messages: [message],
      connection: connection,
      session: session
    )
    _ = try await service.enqueue(
      .markUnread,
      messages: [message],
      connection: connection,
      session: session
    )
    var actions = try store.load(productAccountId: session.productAccountId)
    for index in actions.indices {
      actions[index].state = .providerConfirmed
    }
    try store.save(actions, productAccountId: session.productAccountId)
    try await service.reconcileProviderSync(
      messages: [message],
      connection: connection,
      session: session
    )

    let lookup = try await service.failureLookup(
      .markRead,
      selectedActionIds: selection.pendingActionIds,
      messageIds: [message.providerMessageId],
      connection: connection,
      session: session
    )

    #expect(lookup.coversSelectedMessageIds)
    #expect(lookup.details == [])
    #expect(lookup.matchedPendingActionIds == selection.pendingActionIds)
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testProviderSyncRetainsUnobservedMessagesFromPartiallySupersededAction() async throws {
    let store = InMemoryPendingProviderActionStore()
    let service = PendingProviderActionService(store: store)
    let firstMessage = pendingActionMessage(
      providerMessageId: "message-first",
      providerStateIds: ["INBOX", "UNREAD"]
    )
    let secondMessage = pendingActionMessage(
      providerMessageId: "message-second",
      providerStateIds: ["INBOX", "UNREAD"]
    )
    let selection = try await service.enqueue(
      .markRead,
      messages: [firstMessage, secondMessage],
      connection: connection,
      session: session,
      coalescesMessages: true
    )
    _ = try await service.enqueue(
      .markUnread,
      messages: [firstMessage],
      connection: connection,
      session: session
    )
    var actions = try store.load(productAccountId: session.productAccountId)
    for index in actions.indices {
      actions[index].state = .providerConfirmed
    }
    try store.save(actions, productAccountId: session.productAccountId)

    try await service.reconcileProviderSync(
      messages: [firstMessage],
      connection: connection,
      session: session
    )

    let remainingAction = try requireValue(
      try store.load(productAccountId: session.productAccountId).first)
    #expect(remainingAction.action == .markRead)
    #expect(remainingAction.messageIds == [secondMessage.providerMessageId])

    try await service.reconcileProviderSync(
      messages: [secondMessage],
      connection: connection,
      session: session,
      isConfirmed: { _, _, _ in false }
    )

    let lookup = try await service.failureLookup(
      .markRead,
      selectedActionIds: selection.pendingActionIds,
      messageIds: [firstMessage.providerMessageId, secondMessage.providerMessageId],
      connection: connection,
      session: session
    )
    #expect(lookup.coversSelectedMessageIds)
    #expect(lookup.matchedPendingActionIds == selection.pendingActionIds)
    #expect(lookup.details.map(\.description) == ["The provider did not confirm this action."])
    #expect(
      lookup.details.flatMap(\.messageIds) == [
        StableProviderMessageIdentity(
          connectionId: connection.id,
          providerMessageId: secondMessage.providerMessageId
        )
      ])
  }

  @Test
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
    ) { _, _, _, _ in }
    try await service.perform(
      .restore,
      messages: [message],
      connection: connection,
      session: session
    ) { _, _, _, _ in }
    let pendingActionCount = try await service.pendingActions(session: session).count
    #expect(pendingActionCount == 2)
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
    #expect(pendingActions.isEmpty)
  }

  @Test
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
      Issue.record("Expected Product Account mismatch")
    } catch {
      #expect(error as? PendingProviderActionError == .productAccountMismatch)
    }

    let otherConnection = GmailProviderConnectionStatus(
      connectedAt: 1_781_200_000_000,
      emailAddress: "other@example.com",
      lastVerifiedAt: 1_781_200_000_100,
      provider: "gmail",
      providerAccountIdentifier: "gmail-user-002",
      trustedDeviceId: session.trustedDeviceId,
      updatedAt: 1_781_200_000_200
    ).mailboxConnection(productAccountId: session.productAccountId, authorizationState: .authorized)
    do {
      try await service.enqueue(
        .archive,
        messages: [message],
        connection: otherConnection,
        session: session
      )
      Issue.record("Expected Mailbox Connection mismatch")
    } catch {
      #expect(error as? PendingProviderActionError == .connectionMismatch)
    }
  }

  @Test
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
    ).mailboxConnection(
      productAccountId: otherSession.productAccountId, authorizationState: .authorized)
    let recorder = PendingProviderActionRecorder()
    try await service.perform(
      .archive,
      messages: [
        pendingActionMessage(
          providerMessageId: "message-first-account", providerStateIds: ["INBOX"])
      ],
      connection: connection,
      session: session
    ) { _, _, _, _ in
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
    ) { action, _, _, messageIds in
      let count = await recorder.recordAndCount(action: action, messageIds: messageIds)
      if count == 1 {
        throw URLError(.timedOut)
      }
    }

    try await service.clear(session: session)
    await service.waitForScheduledRetries(connection: otherConnection, session: otherSession)

    let otherActions = try store.load(productAccountId: otherSession.productAccountId)
    let retryCallCount = await recorder.calls.count
    #expect(otherActions.first?.state == .providerConfirmed)
    #expect(retryCallCount == 2)
  }

  @Test
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
      ) { _, _, _, _ in
        throw CancellationError()
      }
      Issue.record("Expected cancellation")
    } catch is CancellationError {
    }

    var actionState = try await service.pendingActions(session: session).first?.state
    #expect(actionState == .pending)
    try await service.resume(
      connection: connection,
      session: session
    ) { _, _, _, _ in }
    actionState = try await service.pendingActions(session: session).first?.state
    #expect(actionState == .providerConfirmed)
  }

  @Test
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
      ) { _, _, _, _ in
        throw URLError(.cancelled)
      }
      Issue.record("Expected cancellation")
    } catch is CancellationError {
    }

    var actionState = try await service.pendingActions(session: session).first?.state
    #expect(actionState == .pending)
    try await service.resume(
      connection: connection,
      session: session
    ) { _, _, _, _ in }
    actionState = try await service.pendingActions(session: session).first?.state
    #expect(actionState == .providerConfirmed)
  }

  @Test
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
    ).mailboxConnection(productAccountId: session.productAccountId, authorizationState: .authorized)

    let gate = PendingProviderActionGate()
    async let firstAction: Void = service.perform(
      .archive,
      messages: [
        pendingActionMessage(providerMessageId: "message-001", providerStateIds: ["INBOX"])
      ],
      connection: connection,
      session: session
    ) { _, _, _, _ in
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
    ) { _, _, _, _ in }
    await gate.release()
    try await firstAction

    let actions = try await service.pendingActions(session: session)
    #expect(
      actions.first { $0.connectionId == connection.id.rawValue }?.state == .providerConfirmed)
    #expect(
      actions.first { $0.connectionId == otherConnection.id.rawValue }?.state == .providerConfirmed)
  }

  @Test
  func testCancellingRetryWaiterDoesNotWaitForStalledProviderWork() async throws {
    let service = PendingProviderActionService(
      store: InMemoryPendingProviderActionStore()
    )
    let gate = PendingProviderActionGate()
    async let providerAction: Void = service.perform(
      .archive,
      messages: [
        pendingActionMessage(providerMessageId: "message-001", providerStateIds: ["INBOX"])
      ],
      connection: connection,
      session: session
    ) { _, _, _, _ in
      await gate.block()
    }
    await gate.waitUntilBlocked()
    let waitCompleted = expectation(description: "Cancelled retry waiter completed")
    let waiter = Task {
      await service.waitForScheduledRetries(
        connection: connection,
        session: session
      )
      waitCompleted.fulfill()
    }

    waiter.cancel()

    await fulfillment(of: [waitCompleted], timeout: 1)
    await gate.release()
    try await providerAction
  }

  private func pendingActionMessage(
    providerMessageId: String,
    providerStateIds: [String],
    connectionId: MailboxConnectionId? = nil
  ) -> MailboxMessageMetadata {
    MailboxMessageMetadata(
      categoryId: nil,
      connectionId: connectionId ?? connection.id,
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

  private var ewsConnection: MailboxConnection {
    MailboxConnection(
      authorizationState: .authorized,
      capabilities: .exchangeWebServices,
      connectedAt: 1_781_200_000_000,
      displayName: "reader@corp.example",
      id: MailboxConnectionId(
        providerMailboxIdentity: StableProviderMailboxIdentity(
          providerId: .exchangeWebServices,
          value: "ews-user-001"
        )
      ),
      lastVerifiedAt: 1_781_200_000_100,
      productAccountId: ProductAccountId(session.productAccountId),
      trustedDeviceId: session.trustedDeviceId,
      updatedAt: 1_781_200_000_200
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
    let sourceProviderMailboxId: String?
    let targetProviderMailboxId: String?
  }

  private(set) var calls: [Call] = []

  func record(
    action: ProviderMailAction,
    sourceProviderMailboxId: String? = nil,
    targetProviderMailboxId: String? = nil,
    messageIds: [String]
  ) {
    calls.append(
      Call(
        action: action,
        messageIds: messageIds,
        sourceProviderMailboxId: sourceProviderMailboxId,
        targetProviderMailboxId: targetProviderMailboxId
      )
    )
  }

  func recordAndCount(action: ProviderMailAction, messageIds: [String]) -> Int {
    record(action: action, messageIds: messageIds)
    return calls.count
  }
}

private actor ProviderActionRevalidationRecorder {
  private(set) var callCount = 0
  private let results: [Bool]

  init(results: [Bool]) {
    self.results = results
  }

  func revalidate() -> Bool {
    defer { callCount += 1 }
    return results[min(callCount, results.count - 1)]
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
