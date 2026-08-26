import Observation

/// Coordinates presentation cleanup without invalidating the mail shell's root view.
@MainActor
@Observable
final class MailPresentationDismissalCoordinator {
  private(set) var revision = 0

  /// Requests that presented mail content be dismissed.
  func dismissPresentations() {
    revision &+= 1
  }
}
