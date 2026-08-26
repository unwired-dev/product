import Testing

@testable import unwired_mail

@Suite("Scheduled Send release policy")
struct ScheduledSendReleasePolicyTests {
  @Test(.bug(id: 386))
  func newSchedulingIsEnabledAfterProtectedProviderCompatibilityCompletes() {
    #expect(ScheduledSendReleasePolicy.protectedProviderCompatibilityComplete)
    #expect(ScheduledSendReleasePolicy.isEnabled)
    #expect(ScheduledSendReleasePolicy.allowsAutomaticScheduling(existingSchedule: false))
    #expect(ScheduledSendReleasePolicy.allowsAutomaticScheduling(existingSchedule: true))
  }
}
