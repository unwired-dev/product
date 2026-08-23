import SwiftUI

@MainActor
struct MailShellThreadProjectionObserver: View {
  let inboxViewModel: GmailInboxViewModel
  let mailShellSelection: MailShellSelectionModel
  let connectionIds: Set<MailboxConnectionId>

  var body: some View {
    Color.clear
      .onChange(of: inboxViewModel.threadProjectionRevision, initial: true) { _, _ in
        synchronizeProjection()
      }
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }

  private func synchronizeProjection() {
    let threads = inboxViewModel.threads
    if mailShellSelection.selectedMailbox?.isUnified == true {
      if let connectionId = inboxViewModel.currentConnectionId {
        mailShellSelection.updateThreads(threads, for: connectionId)
      } else {
        mailShellSelection.replaceUnifiedThreads(threads, connectionIds: connectionIds)
      }
    } else if let connectionId = mailShellSelection.selectedConnectionId {
      mailShellSelection.updateThreads(threads, for: connectionId)
    }
  }
}
