import Foundation
import Testing

@testable import unwired_mail

@Suite(.serialized)
final class MessageAppearanceTests {
  @Test
  func testMessageRequiresLoadedVisibleBodyBeforeMarkingRead() {
    let viewport = CGRect(x: 0, y: 0, width: 600, height: 500)
    let visibleBody = CGRect(x: 20, y: 100, width: 560, height: 300)
    let bodyBelowViewport = CGRect(x: 20, y: 520, width: 560, height: 300)

    #expect(
      !MailShellMessageReadVisibility.isEligible(
        isBodyLoaded: false,
        bodyFrame: visibleBody,
        viewportFrame: viewport
      )
    )
    #expect(
      MailShellMessageReadVisibility.isLoaded(
        freshBodyIsLoaded: false,
        cachedBodyText: "Cached message body"
      )
    )
    #expect(
      !MailShellMessageReadVisibility.isEligible(
        isBodyLoaded: true,
        bodyFrame: visibleBody,
        viewportFrame: .zero
      )
    )
    #expect(
      MailShellMessageReadVisibility.isEligible(
        isBodyLoaded: true,
        bodyFrame: visibleBody,
        viewportFrame: viewport
      )
    )
    #expect(
      !MailShellMessageReadVisibility.isEligible(
        isBodyLoaded: true,
        bodyFrame: bodyBelowViewport,
        viewportFrame: viewport
      )
    )
  }

  @Test
  func testPendingReadBatchCoalescesVisibleMessagesAndDropsHiddenMessages() {
    let connectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .gmail,
        value: "account"
      )
    )
    func message(_ providerMessageId: String, receivedAt: Int64) -> MailboxMessageMetadata {
      MailboxMessageMetadata(
        categoryId: nil,
        connectionId: connectionId,
        from: "sender@example.com",
        isHistorical: false,
        providerInternalDateMilliseconds: receivedAt,
        providerMessageId: providerMessageId,
        providerStateIds: ["INBOX", "UNREAD"],
        providerThreadId: "thread-001",
        recipientHeaders: ["reader@example.com"],
        replyTo: nil,
        rfcMessageId: "<\(providerMessageId)@example.com>",
        snippet: "Message",
        subject: "Subject"
      )
    }
    let first = message("message-first", receivedAt: 100)
    let second = message("message-second", receivedAt: 200)
    let hidden = message("message-hidden", receivedAt: 300)
    var batch = MailShellPendingReadBatch()
    batch.enqueue(second)
    batch.enqueue(first)
    batch.enqueue(hidden)

    let visibleBatch = batch.takeNextVisible([first.id, second.id])

    #expect(visibleBatch?.connectionId == connectionId)
    #expect(visibleBatch?.messages.map(\.id) == [first.id, second.id])
    #expect(batch.isEmpty)
  }

  @Test
  func testPendingReadBatchPartitionsMessagesByConnection() throws {
    func message(
      connectionValue: String,
      providerMessageId: String,
      receivedAt: Int64
    ) -> MailboxMessageMetadata {
      MailboxMessageMetadata(
        categoryId: nil,
        connectionId: MailboxConnectionId(
          providerMailboxIdentity: StableProviderMailboxIdentity(
            providerId: .gmail,
            value: connectionValue
          )
        ),
        from: "sender@example.com",
        isHistorical: false,
        providerInternalDateMilliseconds: receivedAt,
        providerMessageId: providerMessageId,
        providerStateIds: ["INBOX", "UNREAD"],
        providerThreadId: "thread-\(providerMessageId)",
        recipientHeaders: ["reader@example.com"],
        replyTo: nil,
        rfcMessageId: "<\(providerMessageId)@example.com>",
        snippet: "Message",
        subject: "Subject"
      )
    }
    let first = message(connectionValue: "first", providerMessageId: "first", receivedAt: 100)
    let second = message(connectionValue: "second", providerMessageId: "second", receivedAt: 200)
    var batch = MailShellPendingReadBatch()
    batch.enqueue(second)
    batch.enqueue(first)

    let pendingFirstBatch = batch.takeNextVisible([first.id, second.id])
    let pendingSecondBatch = batch.takeNextVisible([first.id, second.id])
    let firstBatch = try #require(pendingFirstBatch)
    let secondBatch = try #require(pendingSecondBatch)

    #expect(firstBatch.connectionId == first.connectionId)
    #expect(firstBatch.messages.map(\.id) == [first.id])
    #expect(secondBatch.connectionId == second.connectionId)
    #expect(secondBatch.messages.map(\.id) == [second.id])
    #expect(batch.isEmpty)
  }

  @Test
  func testOlderReadBatchWorkerCannotClearNewerWorkerOwner() {
    var owner = MailShellReadBatchTaskOwner()
    let olderWorker = owner.begin()

    owner.cancel()
    let newerWorker = owner.begin()

    let olderFinished = owner.finish(olderWorker)
    let newerOwnerSurvived = owner.hasOwner
    let newerFinished = owner.finish(newerWorker)

    #expect(!olderFinished)
    #expect(newerOwnerSurvived)
    #expect(newerFinished)
    #expect(!owner.hasOwner)
  }

  @Test
  func testReadingAppearanceStylesSanitizedHTMLForDarkHighContrastSerifText() throws {
    let sanitized = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p style="font-family: Courier; font-size: 0.9em">Readable message</p>
        """
      ))

    let document = MessageHTMLDocument.styled(
      sanitized,
      style: MessageHTMLStyle(
        colorScheme: .dark,
        increasedContrast: true,
        readingTextSize: .large,
        typeface: .systemSerif
      )
    )

    #expect(document.contains(":root { color-scheme: dark; }"))
    #expect(document.contains("background: transparent;"))
    #expect(document.contains("color: #fff;"))
    #expect(document.contains("-webkit-text-size-adjust: 112.5%;"))
    #expect(!(document.contains("font-size: 112.5%;")))
    #expect(document.contains("font-family: ui-serif, Georgia, serif !important;"))
    #expect(document.contains("font-family:Courier"))
    #expect(document.contains("font-size:0.9em"))
  }

  @Test
  func testSenderFormattingKeepsSanitizedFontsWhileApplyingReadingSizeAndTheme() throws {
    let sanitized = try requireValue(
      MessageHTMLSanitizer.sanitize(
        "<p style=\"font-family: Courier\">Readable message</p>"
      ))

    let document = MessageHTMLDocument.styled(
      sanitized,
      style: MessageHTMLStyle(
        colorScheme: .light,
        increasedContrast: false,
        readingTextSize: .small,
        typeface: .senderFormatting
      )
    )

    #expect(!(document.contains("font-size: 87.5%;")))
    #expect(document.contains("-webkit-text-size-adjust: 87.5%;"))
    #expect(document.contains("<p style=\"font-family:Courier\">"))
    #expect(!(document.contains("body * { font-family:")))
  }
}
