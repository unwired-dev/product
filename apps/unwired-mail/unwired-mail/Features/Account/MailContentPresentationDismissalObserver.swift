import SwiftUI

/// Observes presentation cleanup requests at a leaf view boundary.
struct MailContentPresentationDismissalObserver: View {
  let coordinator: MailPresentationDismissalCoordinator
  let dismissPresentations: () -> Void

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .accessibilityHidden(true)
      .onChange(of: coordinator.revision) { _, _ in
        dismissPresentations()
      }
  }
}
