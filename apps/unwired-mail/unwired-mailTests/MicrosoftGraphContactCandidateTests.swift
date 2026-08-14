import Foundation
import Testing

@testable import unwired_mail

@Suite(.serialized)
final class MicrosoftGraphContactCandidateTests {
  @Test
  func testCandidateKeepsSenderFromAndReplyToRolesDistinct() throws {
    let first = message(
      sender: "Transport Identity <ari@example.com>",
      providerMessageId: "graph-incoming-1",
      replyTo: "Reply Address <ari@example.com>",
      replyToIdentities: ["Reply Address <ari@example.com>"]
    )
    let second = message(
      sender: "Transport Identity <ari@example.com>",
      providerMessageId: "graph-incoming-2",
      replyTo: "Reply Address <ari@example.com>",
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
  func testCandidateRejectsMissingOrAliasedSenderAndReplyTo() {
    let repeated = message(
      sender: "Ari Example <ari@example.com>",
      providerMessageId: "graph-incoming-2"
    )
    let ambiguousMessages = [
      message(sender: nil),
      message(sender: "Assistant <assistant@example.com>"),
      message(
        sender: "Ari Example <ari@example.com>",
        replyTo: "Assistant <assistant@example.com>",
        replyToIdentities: ["Assistant <assistant@example.com>"]
      ),
      message(
        sender: "Ari Example <ari@example.com>",
        replyTo: "Ari Example <ari@example.com>",
        replyToIdentities: [
          "Ari Example <ari@example.com>", "Assistant <assistant@example.com>",
        ]
      ),
    ]

    for candidateMessage in ambiguousMessages {
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

  private func message(
    sender: String?,
    providerMessageId: String = "graph-incoming-1",
    replyTo: String? = nil,
    replyToIdentities: [String]? = nil
  ) -> MailboxMessageMetadata {
    let connectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .microsoftGraph,
        value: "graph-account"
      )
    )
    return MailboxMessageMetadata(
      categoryId: "system:people",
      connectionId: connectionId,
      from: "Ari Example <ari@example.com>",
      isHistorical: false,
      providerInternalDateMilliseconds: 1,
      providerMessageId: providerMessageId,
      providerStateIds: ["INBOX"],
      providerThreadId: "graph-thread-1",
      recipientHeaders: ["Reader <reader@example.com>"],
      replyTo: replyTo,
      rfcMessageId: nil,
      snippet: "Hello",
      subject: "Hello",
      categoryIds: ["system:people"],
      sender: sender,
      replyToIdentities: replyToIdentities
    )
  }
}
