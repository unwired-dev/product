enum ScheduledSendReleasePolicy {
  static let protectedProviderCompatibilityComplete = false

  static var isEnabled: Bool {
    #if DEBUG
      true
    #else
      protectedProviderCompatibilityComplete
    #endif
  }

  static func allowsAutomaticScheduling(existingSchedule: Bool) -> Bool {
    isEnabled || existingSchedule
  }
}
