import Foundation
import SwiftMail
import Testing

@testable import unwired_mail

@Suite("Experimental SwiftMail engine")
struct ExperimentalSwiftMailEngineTests {
  @Test
  func testExactDependencyAndExperimentalBuildPolicy() {
    #expect(SwiftMailExperimentalBuildPolicy.dependencyVersion == "1.10.0")
    #expect(
      SwiftMailExperimentalBuildPolicy.dependencyRevision
        == "c907f871bb23812895274f4c7ae17bf343171c1e"
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
