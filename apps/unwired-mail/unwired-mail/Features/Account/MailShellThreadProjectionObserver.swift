import SwiftUI

@MainActor
struct MailShellThreadProjectionObserver: View {
  @MainActor
  private final class SynchronizationCoordinator {
    private weak var inboxViewModel: GmailInboxViewModel?
    private weak var mailShellSelection: MailShellSelectionModel?
    private var connectionIds: Set<MailboxConnectionId> = []
    private var observationGeneration = 0
    private var pendingAction: (@MainActor () -> Void)?
    private var task: Task<Void, Never>?

    func start(
      inboxViewModel: GmailInboxViewModel,
      mailShellSelection: MailShellSelectionModel,
      connectionIds: Set<MailboxConnectionId>
    ) {
      observationGeneration &+= 1
      self.inboxViewModel = inboxViewModel
      self.mailShellSelection = mailShellSelection
      self.connectionIds = connectionIds
      observe(generation: observationGeneration)
      scheduleSynchronization()
    }

    func updateConnectionIds(_ connectionIds: Set<MailboxConnectionId>) {
      self.connectionIds = connectionIds
      scheduleSynchronization()
    }

    private func observe(generation: Int) {
      guard
        generation == observationGeneration,
        let inboxViewModel,
        let mailShellSelection
      else { return }

      withObservationTracking {
        _ = TaskIdentity(
          revision: inboxViewModel.threadProjectionRevision,
          inboxConnectionId: inboxViewModel.currentConnectionId,
          mailbox: mailShellSelection.selectedMailbox,
          connectionId: mailShellSelection.selectedConnectionId,
          connectionIds: connectionIds
        )
      } onChange: { [weak self] in
        Task { @MainActor [weak self] in
          guard let self, generation == self.observationGeneration else { return }
          self.observe(generation: generation)
          self.scheduleSynchronization()
        }
      }
    }

    private func scheduleSynchronization() {
      guard let identity = taskIdentity else { return }

      schedule { [weak self] in
        guard let self, self.taskIdentity == identity else { return }
        self.synchronizeProjection()
      }
    }

    private func schedule(_ action: @escaping @MainActor () -> Void) {
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
      observationGeneration &+= 1
      task?.cancel()
      task = nil
      pendingAction = nil
      inboxViewModel = nil
      mailShellSelection = nil
    }

    private var taskIdentity: TaskIdentity? {
      guard let inboxViewModel, let mailShellSelection else { return nil }
      return TaskIdentity(
        revision: inboxViewModel.threadProjectionRevision,
        inboxConnectionId: inboxViewModel.currentConnectionId,
        mailbox: mailShellSelection.selectedMailbox,
        connectionId: mailShellSelection.selectedConnectionId,
        connectionIds: connectionIds
      )
    }

    private func synchronizeProjection() {
      guard let inboxViewModel, let mailShellSelection else { return }
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

  private struct TaskIdentity: Equatable {
    let revision: Int
    let inboxConnectionId: MailboxConnectionId?
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
      .onAppear {
        synchronization.start(
          inboxViewModel: inboxViewModel,
          mailShellSelection: mailShellSelection,
          connectionIds: connectionIds
        )
      }
      .onChange(of: connectionIds) { _, connectionIds in
        synchronization.updateConnectionIds(connectionIds)
      }
      .onDisappear {
        synchronization.cancel()
      }
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}
