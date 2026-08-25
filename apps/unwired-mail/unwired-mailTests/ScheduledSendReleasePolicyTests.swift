import Testing

@testable import unwired_mail

@Suite("Scheduled Send release policy")
struct ScheduledSendReleasePolicyTests {
  @Test(.bug(id: 386))
  func newSchedulingIsReleaseGatedWhileExistingCommitmentsRemainEditable() {
    #expect(!ScheduledSendReleasePolicy.protectedProviderCompatibilityComplete)
    #if DEBUG
      #expect(ScheduledSendReleasePolicy.isEnabled)
      #expect(ScheduledSendReleasePolicy.allowsAutomaticScheduling(existingSchedule: false))
    #else
      #expect(!ScheduledSendReleasePolicy.isEnabled)
      #expect(!ScheduledSendReleasePolicy.allowsAutomaticScheduling(existingSchedule: false))
    #endif
    #expect(ScheduledSendReleasePolicy.allowsAutomaticScheduling(existingSchedule: true))
  }
}
