import SwiftUI

@main
struct UnwiredMailApp: App {
  var body: some Scene {
    WindowGroup {
      SmokeView(service: ConvexBackendHealthService())
    }
  }
}
