import Foundation
import Testing

@testable import unwired_mail

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

  private func connection(value: String) -> MailboxConnection {
    let id = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(providerId: .gmail, value: value)
    )
    return MailboxConnection(
      authorizationState: .authorized,
      capabilities: .gmail,
      connectedAt: 1,
      displayName: "\(value)@example.com",
      id: id,
      lastVerifiedAt: 1,
      productAccountId: ProductAccountId("product-account"),
      trustedDeviceId: "trusted-device",
      updatedAt: 1
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
