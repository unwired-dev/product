import SwiftUI

@MainActor
struct MailShellThreadProjectionObserver: View {
  private struct TaskIdentity: Equatable {
    let revision: Int
    let mailbox: MailShellMailboxSelection?
    let connectionId: MailboxConnectionId?
    let connectionIds: Set<MailboxConnectionId>
  }

  let inboxViewModel: GmailInboxViewModel
  let mailShellSelection: MailShellSelectionModel
  let connectionIds: Set<MailboxConnectionId>

  var body: some View {
    Color.clear
      .task(id: taskIdentity) {
        await waitForNextMainRunLoopCycle()
        guard !Task.isCancelled else { return }
        synchronizeProjection()
      }
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }

  private var taskIdentity: TaskIdentity {
    TaskIdentity(
      revision: inboxViewModel.threadProjectionRevision,
      mailbox: mailShellSelection.selectedMailbox,
      connectionId: mailShellSelection.selectedConnectionId,
      connectionIds: connectionIds
    )
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
