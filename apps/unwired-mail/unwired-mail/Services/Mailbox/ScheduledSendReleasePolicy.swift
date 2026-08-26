enum ScheduledSendReleasePolicy {
  static let protectedProviderCompatibilityComplete = true

  static var isEnabled: Bool {
    #if DEBUG
      releaseGateIsEnabled(
        isDebugBuild: true,
        protectedProviderCompatibilityComplete: protectedProviderCompatibilityComplete
      )
    #else
      releaseGateIsEnabled(
        isDebugBuild: false,
        protectedProviderCompatibilityComplete: protectedProviderCompatibilityComplete
      )
    #endif
  }

  /// Returns whether the build and protected-provider evidence open the release gate.
  static func releaseGateIsEnabled(
    isDebugBuild: Bool,
    protectedProviderCompatibilityComplete: Bool
  ) -> Bool {
    isDebugBuild || protectedProviderCompatibilityComplete
  }

  static func allowsAutomaticScheduling(
    existingSchedule: Bool,
    releaseGateIsEnabled: Bool = isEnabled
  ) -> Bool {
    releaseGateIsEnabled || existingSchedule
  }
}
