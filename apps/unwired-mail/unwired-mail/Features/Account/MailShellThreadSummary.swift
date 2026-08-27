import SwiftUI

/// The stable summary at the start of one expanded conversation document.
struct MailShellThreadSummary: View {
  let thread: MailboxThread

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(thread.latestMessage.subject)
        .font(.title2)
        .bold()
        .accessibilityAddTraits(.isHeader)
      HStack(spacing: 8) {
        Label(messageCountText, systemImage: "bubble.left.and.bubble.right")
        if !participants.isEmpty {
          Text(participants.joined(separator: ", "))
            .lineLimit(2)
        }
      }
      .font(.subheadline)
      .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 16)
    .padding(.vertical, 16)
    .accessibilityIdentifier("mail-thread-summary")
  }

  private var messageCountText: String {
    thread.messages.count == 1 ? "1 message" : "\(thread.messages.count) messages"
  }

  private var participants: [String] {
    var seen = Set<String>()
    return thread.messages.compactMap(\.from).filter { seen.insert($0).inserted }
  }
}
