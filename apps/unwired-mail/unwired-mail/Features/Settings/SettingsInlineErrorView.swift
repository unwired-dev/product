import SwiftUI

/// Keeps a destination failure visible beside the values it could not refresh or save.
struct SettingsInlineErrorView: View {
  let message: String
  let isRetrying: Bool
  let retry: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(message, systemImage: "exclamationmark.triangle")
        .foregroundStyle(.red)

      Button("Retry", systemImage: "arrow.clockwise", action: retry)
        .disabled(isRetrying)
    }
    .font(.footnote)
  }
}
