import Foundation
import SwiftMail
import Testing

@testable import unwired_mail

@Suite("Experimental SwiftMail engine – unsubscribe headers")
struct SwiftMailUnsubscribeHeaderTests {
  @Test
  func testStandardsMetadataProjectsFoldedAndRepeatedUnsubscribeHeaders() throws {
    #expect(
      Set(SwiftMailEngineSession.metadataHeaderFields).isSuperset(of: [
        "List-ID", "List-Unsubscribe", "List-Unsubscribe-Post",
      ]))
    let metadata = MailEngineMessageMetadata(
      flags: [],
      identity: MailEngineMessageIdentity(
        connectionID: "connection",
        mailbox: MailEngineMailboxIdentity("INBOX"),
        uid: 7,
        uidValidity: 11
      ),
      internalDate: Date(timeIntervalSince1970: 1_000),
      rfcMessageID: "<message@example.com>",
      headerFields: [
        MailEngineHeaderField(name: "List-ID", value: "Example List <list.example.com>"),
        MailEngineHeaderField(
          name: "List-Unsubscribe",
          value:
            "<mailto:leave@example.com?subject=remove&body=unsubscribe>,\r\n <https://lists.example.com/leave>"
        ),
        MailEngineHeaderField(
          name: "list-unsubscribe",
          value: "<https://backup.example.com/leave>"
        ),
        MailEngineHeaderField(
          name: "List-Unsubscribe-Post",
          value: "List-Unsubscribe=One-Click"
        ),
      ]
    )

    let providerMessage = SwiftMailMailboxClient.providerMessage(metadata)
    let suggestion = try #require(providerMessage.unsubscribeSuggestion)

    #expect(
      suggestion.actions == [
        .oneClick(try #require(URL(string: "https://lists.example.com/leave"))),
        .mailto(
          UnsubscribeMailtoMessage(
            body: "unsubscribe",
            recipient: "leave@example.com",
            subject: "remove"
          )
        ),
        .web(try #require(URL(string: "https://lists.example.com/leave"))),
      ])
    #expect(
      suggestion.mailingListIdentity == MailingListIdentity(rawValue: "list-id:list.example.com"))
  }

  @Test
  func testMetadataFromMessageInfoPreservesWireOrderForDuplicateHeaders() throws {
    let info = MessageInfo(
      sequenceNumber: SequenceNumber(1),
      uid: UID(42),
      additionalHeaderFields: [
        HeaderField(
          name: "List-Unsubscribe",
          value:
            "<mailto:leave@example.com?subject=remove&body=unsubscribe>, <https://lists.example.com/leave>"
        ),
        HeaderField(
          name: "List-Unsubscribe",
          value: "<https://backup.example.com/leave>"
        ),
        HeaderField(name: "List-ID", value: "Example List <list.example.com>"),
        HeaderField(name: "List-Unsubscribe-Post", value: "List-Unsubscribe=One-Click"),
      ]
    )

    let metadata = try SwiftMailEngineSession.metadata(
      info,
      connectionID: "connection",
      mailbox: MailEngineMailboxIdentity("INBOX"),
      uidValidity: 11
    )

    #expect(
      metadata.headerFields.map(\.name) == [
        "list-unsubscribe", "list-unsubscribe", "list-id", "list-unsubscribe-post",
      ])
    #expect(
      metadata.headerFields.map(\.value) == [
        "<mailto:leave@example.com?subject=remove&body=unsubscribe>, <https://lists.example.com/leave>",
        "<https://backup.example.com/leave>",
        "Example List <list.example.com>",
        "List-Unsubscribe=One-Click",
      ])

    let providerMessage = SwiftMailMailboxClient.providerMessage(metadata)
    let suggestion = try #require(providerMessage.unsubscribeSuggestion)

    #expect(
      suggestion.actions == [
        .oneClick(try #require(URL(string: "https://lists.example.com/leave"))),
        .mailto(
          UnsubscribeMailtoMessage(
            body: "unsubscribe",
            recipient: "leave@example.com",
            subject: "remove"
          )
        ),
        .web(try #require(URL(string: "https://lists.example.com/leave"))),
      ])
    #expect(
      suggestion.mailingListIdentity == MailingListIdentity(rawValue: "list-id:list.example.com"))
  }
}
