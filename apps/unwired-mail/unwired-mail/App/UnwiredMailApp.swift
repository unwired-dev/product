import SwiftUI

@main
struct UnwiredMailApp: App {
  init() {
    #if DEBUG
      DotEnvFile.loadDefaultsIfPresent()
    #endif
  }

  var body: some Scene {
    WindowGroup {
      RootView()
    }
  }
}
