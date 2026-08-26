import Testing

@testable import unwired_mail

@Suite("Scheduled Send release policy")
struct ScheduledSendReleasePolicyTests {
  @Test(.bug(id: 386))
  func newSchedulingIsEnabledAfterProtectedProviderCompatibilityCompletes() {
    let releaseGateIsEnabled = ScheduledSendReleasePolicy.releaseGateIsEnabled(
      isDebugBuild: false,
      protectedProviderCompatibilityComplete: true
    )

    #expect(releaseGateIsEnabled)
    #expect(
      ScheduledSendReleasePolicy.allowsAutomaticScheduling(
        existingSchedule: false,
        releaseGateIsEnabled: releaseGateIsEnabled
      )
    )
  }

  @Test(.bug(id: 386))
  func newSchedulingIsReleaseGatedWhileExistingCommitmentsRemainEditable() {
    let releaseGateIsEnabled = ScheduledSendReleasePolicy.releaseGateIsEnabled(
      isDebugBuild: false,
      protectedProviderCompatibilityComplete: false
    )

    #expect(!ScheduledSendReleasePolicy.protectedProviderCompatibilityComplete)
    #expect(!releaseGateIsEnabled)
    #expect(
      !ScheduledSendReleasePolicy.allowsAutomaticScheduling(
        existingSchedule: false,
        releaseGateIsEnabled: releaseGateIsEnabled
      )
    )
    #expect(
      ScheduledSendReleasePolicy.allowsAutomaticScheduling(
        existingSchedule: true,
        releaseGateIsEnabled: releaseGateIsEnabled
      )
    )
  }
}
