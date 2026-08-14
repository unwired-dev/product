import Foundation
import Testing

@testable import unwired_mail

@Suite("Standards-Based Mail Contact Candidates")
struct StandardsMailContactCandidateTests {
  @Test
  func decodesRFCNameAndKeepsEvidenceConnectionScoped() throws {
    let first = message(
      connectionValue: "standards-account",
      from: "=?UTF-8?Q?Jos=C3=A9_Example?= <jose@example.com>",
      providerMessageId: "incoming-1",
      replyTo: "Support alias <JOSE@EXAMPLE.COM>"
    )
    let second = message(
      connectionValue: "standards-account",
      from: "=?UTF-8?B?Sm9zw6kgRXhhbXBsZQ==?= <jose@example.com>",
      providerMessageId: "incoming-2"
    )
    let otherConnectionReply = message(
      connectionValue: "other-standards-account",
      from: "Reader <reader@example.com>",
      providerMessageId: "sent-1",
      providerStateIds: ["SENT"]
    )

    let candidate = try #require(
      ContactCandidateDetector.candidate(
        for: first,
        threadMessages: [first, second],
        mailboxAddress: "reader@example.com",
        cachedBodyText: nil
      )
    )
    #expect(candidate.displayName == "José Example")
    #expect(candidate.emailAddress == "jose@example.com")
    #expect(candidate.evidence == .repeatedCorrespondence)
    #expect(
      ContactCandidateDetector.candidate(
        for: first,
        threadMessages: [first, otherConnectionReply],
        mailboxAddress: "reader@example.com",
        cachedBodyText: nil
      ) == nil
    )
  }

  @Test
  func rejectsGroupsAliasesAndMalformedHeaders() {
    let evidence = message(
      connectionValue: "standards-account",
      providerMessageId: "incoming-2"
    )
    let unsafeMessages = [
      message(
        connectionValue: "standards-account",
        from: "Friends: Ari Example <ari@example.com>;"
      ),
      message(
        connectionValue: "standards-account",
        from: "Ari Example <ari@example.com>, Assistant <assistant@example.com>"
      ),
      message(
        connectionValue: "standards-account",
        from: "\"Ari Example <ari@example.com>"
      ),
      message(
        connectionValue: "standards-account",
        replyTo: "Assistant <assistant@example.com>"
      ),
    ]

    for unsafeMessage in unsafeMessages {
      #expect(
        ContactCandidateDetector.candidate(
          for: unsafeMessage,
          threadMessages: [unsafeMessage, evidence],
          mailboxAddress: "reader@example.com",
          cachedBodyText: nil
        ) == nil
      )
    }
  }

  private func message(
    connectionValue: String,
    from: String = "Ari Example <ari@example.com>",
    providerMessageId: String = "incoming-1",
    providerStateIds: [String] = ["INBOX"],
    replyTo: String? = nil
  ) -> MailboxMessageMetadata {
    let connectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .imapSMTP,
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
      recipientHeaders: ["Reader <reader@example.com>"],
      replyTo: replyTo,
      rfcMessageId: nil,
      snippet: "Hello",
      subject: "Hello",
      categoryIds: ["system:people"]
    )
  }
}
