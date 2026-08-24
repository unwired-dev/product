import SwiftUI

@MainActor
struct MailShellThreadProjectionObserver: View {
  @MainActor
  private final class SynchronizationCoordinator {
    private var pendingAction: (@MainActor () -> Void)?
    private var task: Task<Void, Never>?

    func schedule(_ action: @escaping @MainActor () -> Void) {
      pendingAction = action
      guard task == nil else { return }

      task = Task { @MainActor [weak self] in
        await waitForNextMainRunLoopCycle()
        guard let self, !Task.isCancelled else { return }

        let action = pendingAction
        pendingAction = nil
        task = nil
        action?()
      }
    }

    func cancel() {
      task?.cancel()
      task = nil
      pendingAction = nil
    }
  }

  private struct TaskIdentity: Equatable {
    let revision: Int
    let mailbox: MailShellMailboxSelection?
    let connectionId: MailboxConnectionId?
    let connectionIds: Set<MailboxConnectionId>
  }

  let inboxViewModel: GmailInboxViewModel
  let mailShellSelection: MailShellSelectionModel
  let connectionIds: Set<MailboxConnectionId>
  @State private var synchronization = SynchronizationCoordinator()

  var body: some View {
    Color.clear
      .task(id: taskIdentity) {
        let identity = taskIdentity
        synchronization.schedule {
          guard taskIdentity == identity else { return }
          synchronizeProjection()
        }
      }
      .onDisappear {
        synchronization.cancel()
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
