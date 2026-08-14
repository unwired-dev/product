import Foundation
import Testing

@testable import unwired_mail

@Suite(.serialized)
final class ContactCandidateTests {
  @Test
  func testPeopleCorrespondenceRequiresSameConnectionEvidenceAndDirectRecipient() throws {
    let first = message(providerMessageId: "incoming-1")
    let second = message(providerMessageId: "incoming-2")

    let candidate = try #require(
      ContactCandidateDetector.candidate(
        for: first,
        threadMessages: [first, second],
        mailboxAddress: "reader@example.com",
        cachedBodyText: nil
      )
    )
    #expect(candidate.displayName == "Ari Example")
    #expect(candidate.emailAddress == "ari@example.com")
    #expect(candidate.evidence == .repeatedCorrespondence)

    let otherConnectionReply = message(
      connectionValue: "other-account",
      from: "Reader <reader@example.com>",
      providerMessageId: "other-sent",
      providerStateIds: ["SENT"]
    )
    #expect(
      ContactCandidateDetector.candidate(
        for: first,
        threadMessages: [first, otherConnectionReply],
        mailboxAddress: "reader@example.com",
        cachedBodyText: nil
      ) == nil
    )

    let groupMessage = message(recipientHeaders: ["reader@example.com, team@example.com"])
    #expect(
      ContactCandidateDetector.candidate(
        for: groupMessage,
        threadMessages: [groupMessage, second],
        mailboxAddress: "reader@example.com",
        cachedBodyText: nil
      ) == nil
    )
  }

  @Test
  func testRepeatedCorrespondenceIgnoresUnqualifiedEvidence() {
    let first = message(providerMessageId: "incoming-1")
    var nonPeopleEvidence = message(providerMessageId: "incoming-non-people")
    nonPeopleEvidence.categoryId = "system:invoices"
    nonPeopleEvidence.categoryIds = ["system:invoices"]
    var listEvidence = message(providerMessageId: "incoming-list")
    listEvidence.unsubscribeSuggestion = UnsubscribeSuggestion(
      actions: [],
      mailingListIdentity: MailingListIdentity(rawValue: "list-id:example.com")
    )
    let groupEvidence = message(
      providerMessageId: "incoming-group",
      recipientHeaders: ["reader@example.com, team@example.com"]
    )

    for unqualifiedEvidence in [nonPeopleEvidence, listEvidence, groupEvidence] {
      #expect(
        ContactCandidateDetector.candidate(
          for: first,
          threadMessages: [first, unqualifiedEvidence],
          mailboxAddress: "reader@example.com",
          cachedBodyText: nil
        ) == nil
      )
    }
  }

  @Test
  func testReplyEvidenceAndNormalizedReplyToProduceCandidateWithoutBody() throws {
    let incoming = message(replyTo: "ARI@EXAMPLE.COM")
    let reply = message(
      from: "Reader <reader@example.com>",
      providerMessageId: "sent-1",
      providerStateIds: ["SENT"]
    )

    let candidate = try #require(
      ContactCandidateDetector.candidate(
        for: incoming,
        threadMessages: [incoming, reply],
        mailboxAddress: "reader@example.com",
        cachedBodyText: nil
      )
    )
    #expect(candidate.evidence == .reply)
    #expect(candidate.phoneNumber == nil)
    #expect(candidate.organizationName == nil)
  }

  @Test
  func testDetectionRejectsAliasesListsAutomationAndNonPeopleMail() {
    let repeated = message(providerMessageId: "incoming-2")
    let alias = message(replyTo: "assistant@example.com")
    let automated = message(from: "Updates <no-reply@example.com>")
    var list = message()
    list.unsubscribeSuggestion = UnsubscribeSuggestion(
      actions: [
        .mailto(
          UnsubscribeMailtoMessage(
            body: "unsubscribe",
            recipient: "leave@example.com",
            subject: "unsubscribe"
          )
        )
      ],
      mailingListIdentity: MailingListIdentity(rawValue: "list-id:example.com")
    )
    var nonPeople = message()
    nonPeople.categoryId = "system:invoices"
    nonPeople.categoryIds = ["system:invoices"]

    for candidateMessage in [alias, automated, list, nonPeople] {
      #expect(
        ContactCandidateDetector.candidate(
          for: candidateMessage,
          threadMessages: [candidateMessage, repeated],
          mailboxAddress: "reader@example.com",
          cachedBodyText: nil
        ) == nil
      )
    }
  }

  @Test
  func testCachedSignatureAddsFieldsAndRefreshesOpaqueDismissalIdentity() throws {
    let first = message(providerMessageId: "incoming-1")
    let second = message(providerMessageId: "incoming-2")
    let withoutBody = try #require(
      ContactCandidateDetector.candidate(
        for: first,
        threadMessages: [first, second],
        mailboxAddress: "reader@example.com",
        cachedBodyText: nil
      )
    )
    let withBody = try #require(
      ContactCandidateDetector.candidate(
        for: first,
        threadMessages: [first, second],
        mailboxAddress: "reader@example.com",
        cachedBodyText: """
          Thanks,
          Ari
          --
          Organization: Example Studio
          +1 (415) 555-0100
          Address: 1 Main St, Prague
          https://example.com
          """
      )
    )

    #expect(withBody.organizationName == "Example Studio")
    #expect(withBody.phoneNumber == "+1 (415) 555-0100")
    #expect(withBody.postalAddress == "1 Main St, Prague")
    #expect(withBody.urlString == "https://example.com")
    #expect(withBody.opaqueDismissalIdentifier.count == 64)
    #expect(withBody.opaqueDismissalIdentifier != withoutBody.opaqueDismissalIdentifier)

    let formattingOnlyChange = ContactCandidate(
      displayName: "  ARI   EXAMPLE ",
      emailAddress: withBody.emailAddress,
      evidence: withBody.evidence,
      organizationName: "EXAMPLE STUDIO",
      phoneNumber: "+1 415.555.0100",
      postalAddress: "1 MAIN ST, PRAGUE",
      urlString: "HTTPS://EXAMPLE.COM"
    )
    #expect(formattingOnlyChange.opaqueDismissalIdentifier == withBody.opaqueDismissalIdentifier)
  }

  @MainActor
  @Test
  func testReviewRequestsPermissionBeforeCheckingEmailAndPhoneMatches() async throws {
    var requestedAccess = false
    var reviewedCandidate: ContactCandidate?
    let candidate = ContactCandidate(
      displayName: "Ari Example",
      emailAddress: "ari@example.com",
      evidence: .reply,
      organizationName: nil,
      phoneNumber: "+1 415 555 0100",
      postalAddress: nil,
      urlString: nil
    )
    let service = ContactReviewService(
      requestAccess: {
        requestedAccess = true
        return true
      },
      matchingContactCount: {
        #expect(requestedAccess)
        reviewedCandidate = $0
        return 2
      }
    )

    let review = try await service.prepare(candidate)

    #expect(review.candidate == candidate)
    #expect(review.matchingContactCount == 2)
    #expect(reviewedCandidate == candidate)
  }

  @MainActor
  @Test
  func testReviewStopsWhenContactsAccessIsDenied() async {
    let service = ContactReviewService(
      requestAccess: { false },
      matchingContactCount: { _ in
        Issue.record("Duplicate checks must not run without Contacts permission")
        return 0
      }
    )

    await #expect(throws: ContactReviewError.contactsAccessDenied) {
      try await service.prepare(
        ContactCandidate(
          displayName: "Ari Example",
          emailAddress: "ari@example.com",
          evidence: .reply,
          organizationName: nil,
          phoneNumber: nil,
          postalAddress: nil,
          urlString: nil
        )
      )
    }
  }

  private func message(
    connectionValue: String = "gmail-account",
    from: String = "Ari Example <ari@example.com>",
    providerMessageId: String = "incoming-1",
    providerStateIds: [String] = ["INBOX"],
    recipientHeaders: [String] = ["Reader <reader@example.com>"],
    replyTo: String? = nil
  ) -> MailboxMessageMetadata {
    let connectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .gmail,
        value: connectionValue
      )
    )
    return MailboxMessageMetadata(
      categoryId: "system:people",
      connectionId: connectionId,
      from: from,
      isHistorical: false,
      providerInternalDateMilliseconds: 1,
      providerMessageId: providerMessageId,
      providerStateIds: providerStateIds,
      providerThreadId: "thread-1",
      recipientHeaders: recipientHeaders,
      replyTo: replyTo,
      rfcMessageId: nil,
      snippet: "Hello",
      subject: "Hello",
      categoryIds: ["system:people"]
    )
  }
}

extension ContactCandidateTests {
  @MainActor
  @Test
  func testContactCandidateDismissalLastsThirtyDays() throws {
    let session = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "identity-token",
      productAccountId: "product-account-001",
      trustedDeviceId: "trusted-device-001"
    )
    let store = FeatureSuggestionPreferenceStore(
      session: session,
      syncService: ContactCandidatePreferenceSync(),
      localStateStore: ContactCandidateLocalStateStore(),
      automaticallySynchronizes: false
    )
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    store.dismiss("opaque-contact-001", feature: .addToContacts, now: now)

    #expect(
      !store.isVisible(
        .addToContacts,
        dismissalIdentifier: "opaque-contact-001",
        now: now.addingTimeInterval(30 * 24 * 60 * 60 - 1)
      )
    )
    #expect(
      store.isVisible(
        .addToContacts,
        dismissalIdentifier: "opaque-contact-001",
        now: now.addingTimeInterval(30 * 24 * 60 * 60)
      )
    )
  }
}

private final class ContactCandidateLocalStateStore: FeatureSuggestionLocalStatePersisting {
  private var state: FeatureSuggestionPreferenceLocalState?

  func clear(productAccountId _: String) throws {
    state = nil
  }

  func load(productAccountId _: String) throws -> FeatureSuggestionPreferenceLocalState? {
    state
  }

  func save(
    _ state: FeatureSuggestionPreferenceLocalState,
    productAccountId _: String
  ) throws {
    self.state = state
  }
}

private actor ContactCandidatePreferenceSync: FeatureSuggestionPreferenceSyncing {
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
