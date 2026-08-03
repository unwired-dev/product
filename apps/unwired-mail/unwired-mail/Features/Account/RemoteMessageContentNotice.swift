import SwiftUI

struct RemoteMessageContentNotice: View {
  let policy: RemoteContentLoadPolicy
  let requestLoad: () -> Void
  let state: RemoteMessageContentState

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(
        title,
        systemImage: state.failedImageCount == nil
          ? "eye.slash"
          : "exclamationmark.triangle"
      )
      .font(.subheadline.bold())
      Text(description)
        .font(.caption)
        .foregroundStyle(.secondary)
      if state == .loading {
        ProgressView("Loading remote images…")
          .controlSize(.small)
      } else if showsLoadButton {
        Button(state.failedImageCount == nil ? "Load Remote Images" : "Try Again") {
          requestLoad()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityIdentifier("load-remote-message-content")
      }
    }
    .padding(10)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    .accessibilityIdentifier("remote-message-content-notice")
  }

  var showsLoadButton: Bool {
    state != .loading && policy != .never
  }

  private var title: String {
    if state.failedImageCount != nil {
      return "Some remote images could not be loaded."
    }
    return policy == .never
      ? "Remote images are disabled."
      : "Remote images are blocked."
  }

  private var description: String {
    if policy == .never {
      return "Privacy & Data settings prevent remote images from loading."
    }
    return
      "Loading remote images can reveal your IP address and tell the sender "
      + "that you opened this message."
  }
}
