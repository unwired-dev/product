import Foundation
import Testing

@testable import unwired_mail

// swiftlint:disable file_length type_body_length
struct InboxCleanupTests {
  private let now = Date(timeIntervalSince1970: 2_000_000_000)

  @Test
  func senderThresholdUsesOnlyCompleteEligibleGmailMessages() throws {
    let connection = connection(value: "first")
    let eligible = (0..<10).map { index in
      message(
        connectionId: connection.id,
        from: index.isMultiple(of: 2)
          ? "News (Weekly) <NEWS@example.COM>" : "news@example.com",
        id: "eligible-\(index)",
        threadId: "eligible-thread-\(index)"
      )
    }
    let pinned = message(
      connectionId: connection.id,
      id: "pinned",
      threadId: "pinned-thread"
    )
    let replied = message(
      connectionId: connection.id,
      id: "replied",
      threadId: "replied-thread"
    )
    let sentReply = message(
      connectionId: connection.id,
      categoryIds: [],
      id: "sent-reply",
      providerStateIds: ["SENT"],
      threadId: "replied-thread"
    )
    let ineligible = ineligibleMessages(
      connectionId: connection.id,
      pinned: pinned,
      replied: replied,
      sentReply: sentReply
    )

    let proposal = try #require(
      InboxCleanupDetector.proposal(
        messagesByConnection: [connection.id: eligible + ineligible],
        connections: [connection],
        pinnedThreadIds: [pinned.threadIdentity],
        scope: .connection(connection.id),
        now: now
      )
    )

    #expect(proposal.candidates.map(\.id) == eligible.map(\.id))
  }

  @Test
  func senderThresholdParsesMailboxFromQuotedDisplayName() throws {
    let connection = connection(value: "quoted")
    let messages = (0..<10).map { index in
      message(
        connectionId: connection.id,
        from: #""news@example.com" <news@example.com>"#,
        id: "quoted-\(index)"
      )
    }

    let proposal = try #require(
      InboxCleanupDetector.proposal(
        messagesByConnection: [connection.id: messages],
        connections: [connection],
        pinnedThreadIds: [],
        scope: .connection(connection.id),
        now: now
      )
    )

    #expect(proposal.candidates.count == 10)
  }

  @Test
  func destructiveEligibilityRejectsUnsupportedConnections() {
    let unauthorized = connection(value: "unauthorized", authorizationState: .required)
    let readOnly = connection(value: "read-only", capabilities: .none)
    let reducedProvider = connection(value: "reduced", providerId: .pop3SMTP)

    for candidate in [unauthorized, readOnly, reducedProvider] {
      let messages = (0..<50).map { index in
        message(connectionId: candidate.id, id: "\(candidate.id.rawValue)-\(index)")
      }
      #expect(
        InboxCleanupDetector.proposal(
          messagesByConnection: [candidate.id: messages],
          connections: [candidate],
          pinnedThreadIds: [],
          scope: .connection(candidate.id),
          now: now
        ) == nil
      )
    }
  }

  @Test(
    "Standards-Based Mail uses mapped roles and provider-scoped sender normalization",
    .bug("https://github.com/unwired-dev/product/issues/351")
  )
  func standardsMailUsesMappedRolesAndPreservesSenderCase() throws {
    let connection = standardsConnection(value: "standards")
    let eligible = (0..<10).map { index in
      message(
        connectionId: connection.id,
        from: "Newsletter@Example.COM",
        id: "eligible-\(index)"
      )
    }
    let mappedSpam = message(
      connectionId: connection.id,
      id: "mapped-spam",
      providerStateIds: ["INBOX", "SPAM"]
    )
    let mappedTrash = message(
      connectionId: connection.id,
      id: "mapped-trash",
      providerStateIds: ["INBOX", "TRASH"]
    )

    let proposal = try #require(
      InboxCleanupDetector.proposal(
        messagesByConnection: [connection.id: eligible + [mappedSpam, mappedTrash]],
        connections: [connection],
        pinnedThreadIds: [],
        scope: .connection(connection.id),
        now: now
      )
    )

    #expect(proposal.candidates.map(\.id) == eligible.map(\.id))
    #expect(
      proposal.candidates.first?.normalizedSenderAddress
        == "imap-smtp:Newsletter@example.com"
    )
  }

  @Test(
    "Standards-Based Mail without a safe Trash move never proposes cleanup",
    .bug("https://github.com/unwired-dev/product/issues/351")
  )
  func standardsMailRequiresMappedTrashAndUIDPlus() {
    let roleMappings: [CanonicalMailboxRole: String] = [.sent: "Sent"]
    let missingTrash = connection(
      value: "missing-trash",
      providerId: .imapSMTP,
      capabilities: .standardsMail(
        engineCapabilities: [.uidPlus],
        roleMappings: roleMappings
      )
    )
    let unsafeMove = connection(
      value: "unsafe-move",
      providerId: .imapSMTP,
      capabilities: .standardsMail(
        engineCapabilities: [.move],
        roleMappings: [.trash: "Deleted"]
      )
    )

    for candidate in [missingTrash, unsafeMove] {
      let messages = (0..<50).map { index in
        message(connectionId: candidate.id, id: "\(candidate.id.rawValue)-\(index)")
      }
      #expect(
        InboxCleanupDetector.proposal(
          messagesByConnection: [candidate.id: messages],
          connections: [candidate],
          pinnedThreadIds: [],
          scope: .connection(candidate.id),
          now: now
        ) == nil
      )
    }
  }

  @Test
  func unifiedThresholdDoesNotLeakIntoOneConnectionScope() throws {
    let first = connection(value: "first")
    let second = connection(value: "second")
    let firstMessages = (0..<25).map { index in
      message(
        connectionId: first.id,
        from: "first-\(index)@example.com",
        id: "first-\(index)"
      )
    }
    let secondMessages = (0..<25).map { index in
      message(
        connectionId: second.id,
        from: "second-\(index)@example.com",
        id: "second-\(index)"
      )
    }
    let messages = [first.id: firstMessages, second.id: secondMessages]

    #expect(
      InboxCleanupDetector.proposal(
        messagesByConnection: messages,
        connections: [first, second],
        pinnedThreadIds: [],
        scope: .connection(first.id),
        now: now
      ) == nil
    )
    let unified = try #require(
      InboxCleanupDetector.proposal(
        messagesByConnection: messages,
        connections: [first, second],
        pinnedThreadIds: [],
        scope: .unified,
        now: now
      )
    )
    #expect(unified.candidates.count == 50)
    #expect(Set(unified.candidates.map(\.message.connectionId)) == [first.id, second.id])
  }

  @Test
  func proposalIsBoundedToOldestFiveHundredMessages() throws {
    let connection = connection(value: "first")
    let messages = (0..<550).map { index in
      let ageInMilliseconds = Int64(index + 100) * 24 * 60 * 60 * 1_000
      return message(
        connectionId: connection.id,
        from: "sender-\(index)@example.com",
        id: "message-\(index)",
        receivedAt: milliseconds(now) - ageInMilliseconds
      )
    }

    let proposal = try #require(
      InboxCleanupDetector.proposal(
        messagesByConnection: [connection.id: messages],
        connections: [connection],
        pinnedThreadIds: [],
        scope: .connection(connection.id),
        now: now
      )
    )

    #expect(proposal.candidates.count == 500)
    #expect(proposal.eligibleCandidateCount == 550)
    #expect(proposal.candidates.first?.id == messages.last?.id)
    #expect(proposal.candidates.last?.id == messages[50].id)
  }

  @Test
  func proposalStopsWhenCancellationIsRequested() {
    let connection = connection(value: "cancelled")
    let messages = (0..<50).map { index in
      message(connectionId: connection.id, id: "cancelled-\(index)")
    }
    var cancellationChecks = 0

    let proposal = InboxCleanupDetector.proposal(
      messagesByConnection: [connection.id: messages],
      connections: [connection],
      pinnedThreadIds: [],
      scope: .connection(connection.id),
      now: now,
      shouldCancel: {
        cancellationChecks += 1
        return cancellationChecks > 2
      }
    )

    #expect(proposal == nil)
  }

  @Test
  func revalidationUsesStableMessageIdentityAcrossThreadChanges() {
    let connection = connection(value: "first")
    let stale = message(connectionId: connection.id, id: "stale", threadId: "old-thread")
    let moved = message(connectionId: connection.id, id: "moved", threadId: "old-thread")
    let nowUnread = message(
      connectionId: connection.id,
      id: "stale",
      providerStateIds: ["INBOX", "UNREAD"],
      threadId: "new-thread"
    )
    let movedToNewThread = message(
      connectionId: connection.id,
      id: "moved",
      threadId: "new-thread"
    )

    let result = InboxCleanupDetector.revalidate(
      [stale.id, moved.id],
      messagesByConnection: [connection.id: [nowUnread, movedToNewThread]],
      connections: [connection],
      pinnedThreadIds: [],
      scope: .connection(connection.id),
      now: now
    )

    #expect(result.eligibleCandidates.map(\.id) == [moved.id])
    #expect(result.skippedMessageIds == [stale.id])
  }

  @MainActor
  @Test
  func reviewRequiresReconfirmationAfterRevalidationRemovesMessages() {
    let connection = connection(value: "first")
    let first = InboxCleanupCandidate(
      message: message(connectionId: connection.id, id: "first", threadId: "thread"),
      normalizedSenderAddress: "gmail:sender@example.com"
    )
    let second = InboxCleanupCandidate(
      message: message(connectionId: connection.id, id: "second", threadId: "thread"),
      normalizedSenderAddress: "gmail:sender@example.com"
    )
    let model = InboxCleanupReviewModel(
      proposal: InboxCleanupProposal(candidates: [first, second], scope: .unified)
    )

    model.apply(
      InboxCleanupRevalidation(
        eligibleCandidates: [second],
        skippedMessageIds: [first.id]
      )
    )

    #expect(model.selectedMessageIds == [second.id])
    #expect(model.skippedMessageIds == [first.id])
    model.setSelected(false, group: model.groups[0])
    #expect(model.selectedMessageIds.isEmpty)
  }

  @Test
  // swiftlint:disable:next function_body_length
  func partialFailureOutcomeCountsOnlySelectedSuccessesAndPreservesUndoTruth() {
    let recoverable = connection(value: "recoverable")
    let unrestorable = connection(value: "unrestorable", capabilities: .none)
    let failed = message(connectionId: recoverable.id, id: "failed")
    let restored = message(connectionId: recoverable.id, id: "restored")
    let cannotRestore = message(connectionId: unrestorable.id, id: "cannot-restore")
    let failure = MailboxBulkActionFailure(
      connectionId: recoverable.id,
      connectionDisplayName: recoverable.displayName,
      description: "Provider rejected one message.",
      messageIds: [
        failed.id,
        StableProviderMessageIdentity(connectionId: recoverable.id, providerMessageId: "outside"),
      ],
      messageCount: 2,
      messageSubjects: []
    )
    let result = MailboxBulkActionResult(
      deferredConnectionIds: [],
      failures: [failure],
      succeededConnectionIds: [unrestorable.id]
    )

    let outcome = InboxCleanupExecutionOutcome.deletion(
      result: result,
      batches: [
        MailboxBulkActionBatch(connection: recoverable, messages: [failed, restored]),
        MailboxBulkActionBatch(connection: unrestorable, messages: [cannotRestore]),
      ]
    )

    #expect(outcome.messageCount == 2)
    #expect(outcome.unrestorableMessageCount == 1)
    #expect(outcome.undoBatches.count == 1)
    #expect(outcome.undoBatches[0].messages.map(\.id) == [restored.id])

    let restorationFailure = MailboxBulkActionFailure(
      connectionId: recoverable.id,
      connectionDisplayName: recoverable.displayName,
      description: "Provider rejected the restore.",
      messageIds: [restored.id],
      messageCount: 1,
      messageSubjects: []
    )
    let restorationResult = MailboxBulkActionResult(
      deferredConnectionIds: [],
      failures: [restorationFailure],
      succeededConnectionIds: []
    )
    let undoFailure = InboxCleanupExecutionOutcome.restorationFailure(
      restorationResult,
      batches: outcome.undoBatches
    )
    #expect(undoFailure.failures == [restorationFailure])
    #expect(undoFailure.messageCount == 0)
    #expect(undoFailure.undoBatches.count == 1)
    #expect(undoFailure.undoBatches[0].messages.map(\.id) == [restored.id])
  }

  private func connection(
    value: String,
    providerId: MailProviderId = .gmail,
    authorizationState: MailboxAuthorizationState = .authorized,
    capabilities: MailboxConnectionCapabilities = .gmail
  ) -> MailboxConnection {
    let id = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(providerId: providerId, value: value)
    )
    return MailboxConnection(
      authorizationState: authorizationState,
      capabilities: capabilities,
      connectedAt: 1,
      displayName: "\(value)@example.com",
      id: id,
      lastVerifiedAt: 1,
      productAccountId: ProductAccountId("product-account"),
      trustedDeviceId: "trusted-device",
      updatedAt: 1
    )
  }

  private func standardsConnection(value: String) -> MailboxConnection {
    connection(
      value: value,
      providerId: .imapSMTP,
      capabilities: .standardsMail(
        engineCapabilities: [.uidPlus],
        roleMappings: [
          .sent: "Sent",
          .spam: "Junk",
          .trash: "Deleted",
        ]
      )
    )
  }

  private func message(
    connectionId: MailboxConnectionId,
    from: String = "news@example.com",
    categoryIds: [String] = ["system:promotions"],
    id: String,
    providerStateIds: [String] = ["INBOX"],
    receivedAt: Int64? = nil,
    threadId: String? = nil
  ) -> MailboxMessageMetadata {
    MailboxMessageMetadata(
      categoryId: categoryIds.first,
      connectionId: connectionId,
      from: from,
      isHistorical: true,
      providerInternalDateMilliseconds:
        receivedAt ?? milliseconds(now) - 91 * 24 * 60 * 60 * 1_000,
      providerMessageId: id,
      providerStateIds: providerStateIds,
      providerThreadId: threadId ?? "thread-\(id)",
      recipientHeaders: ["reader@example.com"],
      replyTo: nil,
      rfcMessageId: nil,
      snippet: "Newsletter",
      subject: "Newsletter \(id)",
      categoryIds: categoryIds
    )
  }

  private func milliseconds(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1_000).rounded(.down))
  }

  private func ineligibleMessages(
    connectionId: MailboxConnectionId,
    pinned: MailboxMessageMetadata,
    replied: MailboxMessageMetadata,
    sentReply: MailboxMessageMetadata
  ) -> [MailboxMessageMetadata] {
    [
      message(
        connectionId: connectionId,
        id: "unread",
        providerStateIds: ["INBOX", "UNREAD"]
      ),
      message(
        connectionId: connectionId,
        categoryIds: ["system:promotions", "system:people"],
        id: "people"
      ),
      message(connectionId: connectionId, id: "spam", providerStateIds: ["INBOX", "SPAM"]),
      message(connectionId: connectionId, id: "trash", providerStateIds: ["INBOX", "TRASH"]),
      message(
        connectionId: connectionId,
        id: "too-new",
        receivedAt: milliseconds(now) - 90 * 24 * 60 * 60 * 1_000
      ),
      pinned,
      replied,
      sentReply,
    ]
  }
}

@MainActor
struct InboxCleanupPreferenceTests {
  private let now = Date(timeIntervalSince1970: 2_000_000_000)

  @Test
  func cooldownReturnsEarlyOnlyAfterCandidateCountDoubles() {
    let session = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user",
      identityToken: "identity-token",
      productAccountId: "product-account",
      trustedDeviceId: "trusted-device"
    )
    let stateStore = InboxCleanupFeatureSuggestionStateStore()
    let store = FeatureSuggestionPreferenceStore(
      session: session,
      syncService: InboxCleanupFeatureSuggestionSync(),
      localStateStore: stateStore,
      automaticallySynchronizes: false
    )
    let scope = InboxCleanupScope.unified.preferenceIdentifier

    store.recordInboxCleanupDisplay(scopeIdentifier: scope, candidateCount: 50, now: now)
    #expect(
      store.inboxCleanupPresentation(scopeIdentifier: scope, candidateCount: 99, now: now)
        == .hidden)
    #expect(
      store.inboxCleanupPresentation(scopeIdentifier: scope, candidateCount: 100, now: now)
        == .consumeEarlyReturn
    )
    store.recordInboxCleanupDisplay(scopeIdentifier: scope, candidateCount: 100, now: now)
    #expect(
      store.inboxCleanupPresentation(scopeIdentifier: scope, candidateCount: 100, now: now)
        == .hidden)
    #expect(
      store.inboxCleanupPresentation(
        scopeIdentifier: scope,
        candidateCount: 100,
        now: now.addingTimeInterval(30 * 24 * 60 * 60)
      ) == .visible
    )

    let restored = FeatureSuggestionPreferenceStore(
      session: session,
      syncService: InboxCleanupFeatureSuggestionSync(),
      localStateStore: stateStore,
      automaticallySynchronizes: false
    )
    #expect(
      restored.inboxCleanupPresentation(scopeIdentifier: scope, candidateCount: 199, now: now)
        == .hidden)
    #expect(
      restored.inboxCleanupPresentation(scopeIdentifier: scope, candidateCount: 200, now: now)
        == .consumeEarlyReturn
    )
  }

  @Test
  func baselineStorageDoesNotChangeDismissalDeadlines() {
    var preferences = FeatureSuggestionPreferences.defaults
    preferences.apply(
      .dismiss("scope", feature: .inboxCleanup, untilMilliseconds: 1_000)
    )
    preferences.apply(
      .setStoredValue(50, identifier: "scope", feature: .inboxCleanup)
    )

    #expect(
      preferences.isVisible(.inboxCleanup, dismissalIdentifier: "scope", nowMilliseconds: 999)
        == false
    )
    #expect(preferences.storedValue(.inboxCleanup, identifier: "scope") == 50)
  }

  @Test
  func connectionScopePreferenceIdentifierIsOpaque() {
    let connectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .gmail,
        value: "private-mailbox-identity"
      )
    )

    let identifier = InboxCleanupScope.connection(connectionId).preferenceIdentifier

    #expect(identifier.hasPrefix("connection:"))
    #expect(identifier.contains("private-mailbox-identity") == false)
  }
}

private final class InboxCleanupFeatureSuggestionStateStore: FeatureSuggestionLocalStatePersisting {
  private var states: [String: FeatureSuggestionPreferenceLocalState] = [:]

  func clear(productAccountId: String) throws {
    states[productAccountId] = nil
  }

  func load(productAccountId: String) throws -> FeatureSuggestionPreferenceLocalState? {
    states[productAccountId]
  }

  func save(
    _ state: FeatureSuggestionPreferenceLocalState,
    productAccountId: String
  ) throws {
    states[productAccountId] = state
  }
}

private actor InboxCleanupFeatureSuggestionSync: FeatureSuggestionPreferenceSyncing {
  func apply(
    _ mutations: [FeatureSuggestionPreferenceMutation],
    session _: ProductAccountSessionSnapshot
  ) async throws -> FeatureSuggestionPreferences {
    FeatureSuggestionPreferences.defaults.applying(mutations)
  }

  func loadPreferences(
    session _: ProductAccountSessionSnapshot
  ) async throws -> FeatureSuggestionPreferences? {
    nil
  }
}
