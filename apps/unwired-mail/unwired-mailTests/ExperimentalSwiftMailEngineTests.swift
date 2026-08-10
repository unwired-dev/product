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
}
