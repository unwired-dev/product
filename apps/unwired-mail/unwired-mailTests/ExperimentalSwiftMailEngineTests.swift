import Foundation
import SwiftMail
import Testing

@testable import unwired_mail

@Suite("Experimental SwiftMail engine")
struct ExperimentalSwiftMailEngineTests {
  @Test
  func testExactDependencyAndExperimentalBuildPolicy() {
    #expect(SwiftMailExperimentalBuildPolicy.dependencyVersion == "1.11.0")
    #expect(
      SwiftMailExperimentalBuildPolicy.dependencyRevision
        == "a2d4a94f844db62843ef6aec16f3ed9462152acc"
    )
    #expect(SwiftMailExperimentalBuildPolicy.providerCertificationIssue == 280)
    #expect(!SwiftMailExperimentalBuildPolicy.providerCertificationComplete)
    #expect(SwiftMailExperimentalBuildPolicy.isEnabled)
  }

  @Test
  func testSMTPFinalResponseClassificationPreserves499And500Boundary() {
    let transient = SMTPSendError(
      phase: .content,
      acceptance: .rejectedTransiently,
      reason: .reply(SMTPResponse(code: 499, message: "retry later"))
    )
    let permanent = SMTPSendError(
      phase: .content,
      acceptance: .rejectedPermanently,
      reason: .reply(SMTPResponse(code: 500, message: "rejected"))
    )

    #expect(SwiftMailEngineSession.smtpOutcome(transient) == .transientlyRejected(code: 499))
    #expect(SwiftMailEngineSession.smtpOutcome(permanent) == .permanentlyRejected(code: 500))
  }

  @Test
  func testSMTPAmbiguousPostContentFailureIsNeverRetryable() {
    let ambiguous = SMTPSendError(
      phase: .content,
      acceptance: .ambiguous,
      reason: .connectionLost
    )

    #expect(SwiftMailEngineSession.smtpOutcome(ambiguous) == .ambiguous)
  }

  @Test
  func testSMTPPreContentRejectionsKeepTheirPhaseAndCode() {
    let sender = SMTPSendError(
      phase: .mailFrom,
      acceptance: .notAccepted,
      reason: .reply(SMTPResponse(code: 550, message: "sender rejected"))
    )
    let recipient = SMTPSendError(
      phase: .rcptTo,
      acceptance: .notAccepted,
      reason: .reply(SMTPResponse(code: 450, message: "recipient unavailable"))
    )
    let data = SMTPSendError(
      phase: .data,
      acceptance: .notAccepted,
      reason: .reply(SMTPResponse(code: 554, message: "data rejected"))
    )

    #expect(
      SwiftMailEngineSession.smtpOutcome(sender)
        == .notSubmitted(.senderRejected(code: 550))
    )
    #expect(
      SwiftMailEngineSession.smtpOutcome(recipient)
        == .notSubmitted(.recipientRejected(code: 450))
    )
    #expect(
      SwiftMailEngineSession.smtpOutcome(data)
        == .notSubmitted(.dataRejected(code: 554))
    )
  }

  @Test
  func testSMTPPreContentConnectionLossRemainsTransportUnavailable() {
    let connectionLost = SMTPSendError(
      phase: .mailFrom,
      acceptance: .notAccepted,
      reason: .connectionLost
    )

    #expect(
      SwiftMailEngineSession.smtpOutcome(connectionLost)
        == .notSubmitted(.transportUnavailable)
    )
  }

  @Test
  func testCapabilitiesRequireExactTokens() {
    #expect(
      ExperimentalSwiftMailEngine.capabilities(
        ["IDLE", "MOVE", "SPECIAL-USE", "UIDPLUS"],
        mailboxes: []
      ) == [.idle, .move, .specialUse, .uidPlus]
    )
    #expect(
      ExperimentalSwiftMailEngine.capabilities(
        ["X-IDLE", "XMOVE", "SPECIAL-USE-EXTENDED", "X-UIDPLUS"],
        mailboxes: []
      ).isEmpty
    )
  }

  @Test
  func testCapabilityNamesUseProtocolNamesInsteadOfDebugDescriptions() {
    #expect(
      ExperimentalSwiftMailEngine.capabilityNames([
        "idle", "MOVE", "UIDPLUS",
      ]) == ["IDLE", "MOVE", "UIDPLUS"]
    )
  }

  @Test
  func testPreferredBodyPartDoesNotSelectAttachments() throws {
    let parts = [
      MessagePart(sectionString: "1", contentType: "text/html; charset=utf-8"),
      MessagePart(sectionString: "2", contentType: "text/plain; charset=utf-8"),
      MessagePart(
        sectionString: "3",
        contentType: "text/plain; charset=utf-8",
        disposition: "attachment",
        filename: "note.txt"
      ),
    ]

    let selected = try #require(SwiftMailEngineSession.preferredBodyPart(parts))

    #expect(selected.section == Section("2"))
  }

  @Test
  func testPreferredBodyPartFallsBackToHTMLWhenOnlyPlainTextIsAttached() throws {
    let parts = [
      MessagePart(sectionString: "1", contentType: "text/html; charset=utf-8"),
      MessagePart(
        sectionString: "2",
        contentType: "text/plain; charset=utf-8",
        disposition: "attachment",
        filename: "note.txt"
      ),
    ]

    let selected = try #require(SwiftMailEngineSession.preferredBodyPart(parts))

    #expect(selected.section == Section("1"))
  }

  @Test
  func testPlainTextConversionUsesHTMLParserAndDecodesEntities() {
    #expect(
      SwiftMailEngineSession.plainText(
        fromHTML: "<style>hidden</style><div>One&nbsp;<strong>Two</strong> &#169;</div>"
      ).trimmingCharacters(in: .whitespacesAndNewlines) == "One Two ©"
    )
  }

  @Test
  func testPageValidationRejectsInvalidBounds() {
    #expect(throws: MailEngineError.protocolRejected(code: "INVALID-PAGE", retryable: false)) {
      try SwiftMailEngineSession.validatePage(beforeUID: nil, limit: 0)
    }
    #expect(throws: MailEngineError.protocolRejected(code: "INVALID-PAGE", retryable: false)) {
      try SwiftMailEngineSession.validatePage(beforeUID: nil, limit: 501)
    }
    #expect(throws: MailEngineError.protocolRejected(code: "INVALID-PAGE", retryable: false)) {
      try SwiftMailEngineSession.validatePage(beforeUID: Int64(UInt32.max) + 1, limit: 50)
    }
  }

  @Test
  func testMissingCopyUIDAndMessageUIDAreRejected() {
    #expect(throws: MailEngineUIDMappingError.invalidUID) {
      try SwiftMailEngineSession.mapping(
        nil,
        sourceMailbox: MailEngineMailboxIdentity("INBOX"),
        sourceUIDValidity: 1,
        requestedSourceUIDs: [1],
        destinationMailbox: MailEngineMailboxIdentity("Sent")
      )
    }
    #expect(throws: MailEngineUIDMappingError.invalidUID) {
      try SwiftMailEngineSession.metadata(
        MessageInfo(sequenceNumber: SequenceNumber(1)),
        connectionID: "connection",
        mailbox: MailEngineMailboxIdentity("INBOX"),
        uidValidity: 1
      )
    }
    #expect(throws: MailEngineUIDMappingError.invalidUID) {
      try SwiftMailEngineSession.metadata(
        MessageInfo(sequenceNumber: SequenceNumber(1), uid: UID(0)),
        connectionID: "connection",
        mailbox: MailEngineMailboxIdentity("INBOX"),
        uidValidity: 1
      )
    }
  }

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
  func testTransportErrorsPreserveMutationUncertainty() {
    #expect(
      ExperimentalSwiftMailEngine.connectionError(IMAPError.connectionFailed("offline"))
        == .connectionClosed
    )
    #expect(
      SwiftMailEngineSession.mutationError(IMAPError.connectionFailed("offline"))
        == .operationOutcomeUnknown
    )
  }
}

@Suite("Experimental SwiftMail calendar parts")
struct ExperimentalSwiftMailCalendarPartTests {
  @Test
  func testMetadataDetectsCalendarStructureWithoutPartData() throws {
    let metadata = try SwiftMailEngineSession.metadata(
      MessageInfo(
        sequenceNumber: SequenceNumber(1),
        uid: UID(7),
        parts: [
          MessagePart(
            sectionString: "1",
            contentType: "application/pdf",
            disposition: "attachment",
            filename: "agenda.pdf",
            size: 2_048,
            data: Data("must not be read".utf8)
          ),
          MessagePart(
            sectionString: "2.1",
            contentType: "text/calendar; method=REQUEST",
            encoding: "base64",
            filename: "invite.ics",
            size: 512
          ),
          MessagePart(
            sectionString: "2.2",
            contentType: "text/x-vcalendar",
            size: 128
          ),
        ]
      ),
      connectionID: "connection",
      mailbox: MailEngineMailboxIdentity("INBOX"),
      uidValidity: 4
    )

    #expect(
      metadata.calendarInvitationPart
        == MailEngineBodyPartDescriptor(
          byteCount: 512,
          contentTransferEncoding: "base64",
          mimeType: "text/calendar",
          selector: MailEngineBodyPartSelector("2.1")
        ))
    #expect(metadata.hasAttachments)
  }

  @Test
  func testCalendarStructureIgnoresOrdinaryICSFilenameAndUnsupportedMIME() {
    let invitation = SwiftMailEngineSession.calendarInvitationPart([
      MessagePart(
        sectionString: "1",
        contentType: "application/octet-stream",
        disposition: "attachment",
        filename: "invite.ics",
        size: 128
      ),
      MessagePart(
        sectionString: "2",
        contentType: "application/calendar",
        size: 128
      ),
      MessagePart(
        sectionString: "3",
        contentType: "text/calendar"
      ),
    ])

    #expect(invitation == nil)
  }

  @Test
  func testCalendarPartDecodingEnforcesDeclaredAndDecodedSizeLimits() throws {
    let descriptor = MailEngineBodyPartDescriptor(
      byteCount: 24,
      contentTransferEncoding: "base64",
      mimeType: "text/calendar",
      selector: MailEngineBodyPartSelector("2")
    )
    let value = Data("BEGIN:VCALENDAR".utf8)

    let decoded = try SwiftMailEngineSession.decodedBodyPart(
      Data(value.base64EncodedString().utf8),
      descriptor: descriptor,
      maximumByteCount: 24
    )

    #expect(decoded == value)
    #expect(
      throws: MailEngineError.protocolRejected(code: "BODY-PART-TOO-LARGE", retryable: false)
    ) {
      try SwiftMailEngineSession.decodedBodyPart(
        Data(value.base64EncodedString().utf8),
        descriptor: descriptor,
        maximumByteCount: 15
      )
    }
    let understatedDescriptor = MailEngineBodyPartDescriptor(
      byteCount: 15,
      contentTransferEncoding: "base64",
      mimeType: "text/calendar",
      selector: MailEngineBodyPartSelector("2")
    )
    let oversizedValue = Data("BEGIN:VCALENDARX".utf8)
    #expect(
      throws: MailEngineError.protocolRejected(code: "BODY-PART-TOO-LARGE", retryable: false)
    ) {
      try SwiftMailEngineSession.decodedBodyPart(
        Data(oversizedValue.base64EncodedString().utf8),
        descriptor: understatedDescriptor,
        maximumByteCount: 15
      )
    }
  }

  @Test
  func testCalendarPartFetchParserRejectsAnUnderstatedServerBodyBeforeAccumulation() {
    let maximumByteCount = CalendarInvitationDescriptor.maximumByteCount

    #expect(
      SwiftMailEngineSession.bodyPartParserLimits(maximumByteCount: maximumByteCount)
        == IMAPParserLimits(bodySizeLimit: UInt64(maximumByteCount))
    )
  }
}
