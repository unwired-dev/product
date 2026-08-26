import SwiftUI

/// Keeps a destination failure visible beside the values it could not refresh or save.
struct SettingsInlineErrorView: View {
  let message: String
  let isRetrying: Bool
  let retry: (() -> Void)?

  init(message: String, isRetrying: Bool, retry: (() -> Void)? = nil) {
    self.message = message
    self.isRetrying = isRetrying
    self.retry = retry
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(message, systemImage: "exclamationmark.triangle")
        .foregroundStyle(.red)

      if let retry {
        Button("Retry", systemImage: "arrow.clockwise", action: retry)
          .disabled(isRetrying)
      }
    }
    .font(.footnote)
  }
}
