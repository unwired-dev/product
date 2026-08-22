/// The Settings surface that should open for the current build and Product Account state.
enum SettingsPresentation: Equatable {
  case accountSettings
  case adaptiveSettings

  /// Resolves the signed-out release slice without enabling signed-in adaptive Settings early.
  static func resolve(
    isSignedIn: Bool,
    isDevelopmentBuild: Bool
  ) -> Self {
    isSignedIn && !isDevelopmentBuild ? .accountSettings : .adaptiveSettings
  }

  /// The presentation selected by the current build configuration.
  static func current(isSignedIn: Bool) -> Self {
    #if DEBUG
      resolve(isSignedIn: isSignedIn, isDevelopmentBuild: true)
    #else
      resolve(isSignedIn: isSignedIn, isDevelopmentBuild: false)
    #endif
  }
}
