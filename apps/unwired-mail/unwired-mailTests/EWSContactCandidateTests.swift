import Foundation
import Testing

@testable import unwired_mail

@Suite("Exchange Web Services Contact Candidates")
struct EWSContactCandidateTests {
  @Test
  func candidateKeepsSenderOrganizerAndReplyToRolesDistinct() throws {
    let first = message(
      organizer: "Meeting Organizer <ARI@EXAMPLE.COM>",
      providerMessageId: "ews-incoming-1",
      replyToIdentities: ["Reply Address <ari@example.com>"]
    )
    let second = message(
      organizer: "Meeting Organizer <ari@example.com>",
      providerMessageId: "ews-incoming-2",
      replyToIdentities: ["Reply Address <ari@example.com>"]
    )

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
  }

  @Test
  func candidateRejectsMissingDelegatedAliasedOrAmbiguousIdentities() {
    let evidence = message(providerMessageId: "ews-incoming-2")
    let ambiguousMessages = [
      message(sender: nil),
      message(sender: "Assistant <assistant@example.com>"),
      message(organizer: "Assistant <assistant@example.com>"),
      message(replyToIdentities: ["Assistant <assistant@example.com>"]),
      message(
        replyToIdentities: [
          "Ari Example <ari@example.com>", "Assistant <assistant@example.com>",
        ]
      ),
    ]

    for candidateMessage in ambiguousMessages {
      #expect(
        ContactCandidateDetector.candidate(
          for: candidateMessage,
          threadMessages: [candidateMessage, evidence],
          mailboxAddress: "reader@example.com",
          cachedBodyText: nil
        ) == nil
      )
    }
  }

  @Test
  func replyEvidenceRemainsScopedToTheOwningConnection() throws {
    let incoming = message()
    let otherConnectionReply = message(
      connectionValue: "other-ews-account",
      from: "Reader <reader@example.com>",
      providerMessageId: "other-sent",
      providerStateIds: ["SENT"],
      sender: "Reader <reader@example.com>"
    )
    let owningConnectionReply = message(
      from: "Reader <reader@example.com>",
      providerMessageId: "owning-sent",
      providerStateIds: ["SENT"],
      sender: "Reader <reader@example.com>"
    )

    #expect(
      ContactCandidateDetector.candidate(
        for: incoming,
        threadMessages: [incoming, otherConnectionReply],
        mailboxAddress: "reader@example.com",
        cachedBodyText: nil
      ) == nil
    )
    let candidate = try #require(
      ContactCandidateDetector.candidate(
        for: incoming,
        threadMessages: [incoming, owningConnectionReply],
        mailboxAddress: "reader@example.com",
        cachedBodyText: nil
      )
    )
    #expect(candidate.evidence == .reply)
  }

  private func message(
    connectionValue: String = "ews-account",
    from: String = "Ari Example <ari@example.com>",
    organizer: String? = nil,
    providerMessageId: String = "ews-incoming-1",
    providerStateIds: [String] = ["INBOX"],
    replyToIdentities: [String]? = nil,
    sender: String? = "Transport Identity <ari@example.com>"
  ) -> MailboxMessageMetadata {
    let connectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .exchangeWebServices,
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
      providerThreadId: "ews-thread-1",
      recipientHeaders: ["Reader <reader@example.com>"],
      replyTo: replyToIdentities?.first,
      rfcMessageId: nil,
      snippet: "Hello",
      subject: "Hello",
      categoryIds: ["system:people"],
      sender: sender,
      organizer: organizer,
      replyToIdentities: replyToIdentities
    )
  }
}
