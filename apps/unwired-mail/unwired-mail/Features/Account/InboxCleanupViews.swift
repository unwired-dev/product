import SwiftUI

struct InboxCleanupExecutionOutcome: Equatable, Identifiable {
  let failures: [MailboxBulkActionFailure]
  let id = UUID()
  let messageCount: Int
  let unrestorableMessageCount: Int
  let undoBatches: [MailboxBulkActionBatch]

  var title: String {
    if messageCount == 0 { return "Cleanup needs attention" }
    return failures.isEmpty ? "Inbox Cleanup queued" : "Inbox Cleanup partially queued"
  }

  static func deletion(
    result: MailboxBulkActionResult,
    batches: [MailboxBulkActionBatch]
  ) -> Self {
    let failedMessageIds = Set(result.failures.flatMap(\.messageIds))
    let succeededMessageCount = batches.flatMap(\.messages).count {
      failedMessageIds.contains($0.id) == false
    }
    let unrestorableMessageCount = batches.reduce(into: 0) { count, batch in
      guard batch.connection.capabilities.supports(.restore) == false else { return }
      count += batch.messages.count { failedMessageIds.contains($0.id) == false }
    }
    let undoBatches = batches.compactMap { batch -> MailboxBulkActionBatch? in
      guard batch.connection.capabilities.supports(.restore) else { return nil }
      let messages = batch.messages.filter { failedMessageIds.contains($0.id) == false }
      guard messages.isEmpty == false else { return nil }
      return MailboxBulkActionBatch(connection: batch.connection, messages: messages)
    }
    return Self(
      failures: result.failures,
      messageCount: succeededMessageCount,
      unrestorableMessageCount: unrestorableMessageCount,
      undoBatches: undoBatches
    )
  }

  static func restorationFailure(
    _ result: MailboxBulkActionResult,
    batches: [MailboxBulkActionBatch]
  ) -> Self {
    let failedMessageIds = Set(result.failures.flatMap(\.messageIds))
    let retryBatches = batches.compactMap { batch -> MailboxBulkActionBatch? in
      let messages = batch.messages.filter { failedMessageIds.contains($0.id) }
      guard messages.isEmpty == false else { return nil }
      return MailboxBulkActionBatch(connection: batch.connection, messages: messages)
    }
    return Self(
      failures: result.failures,
      messageCount: 0,
      unrestorableMessageCount: 0,
      undoBatches: retryBatches
    )
  }
}

struct InboxCleanupProposalCard: View {
  let proposal: InboxCleanupProposal
  let disable: () -> Void
  let dismiss: () -> Void
  let review: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("Inbox Cleanup", systemImage: "sparkles")
        .font(.headline)
      Text(
        "Review \(proposal.candidates.count) older newsletters and promotions before moving "
          + "them to Trash. Nothing is permanently erased."
      )
      .font(.subheadline)
      .foregroundStyle(.secondary)
      HStack(spacing: 8) {
        Button("Review", action: review)
          .buttonStyle(.borderedProminent)
        Button("Not Now", action: dismiss)
          .buttonStyle(.bordered)
        Menu("More", systemImage: "ellipsis.circle") {
          Button("Turn Off Inbox Cleanup Suggestions", action: disable)
        }
        .labelStyle(.iconOnly)
      }
    }
    .padding(.vertical, 12)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("inbox-cleanup-proposal")
  }
}

struct InboxCleanupOutcomeCard: View {
  let outcome: InboxCleanupExecutionOutcome
  let isUndoing: Bool
  let dismiss: () -> Void
  let undo: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(
        outcome.title, systemImage: outcome.failures.isEmpty ? "trash" : "exclamationmark.triangle"
      )
      .font(.headline)
      if outcome.messageCount > 0 {
        Text("^[\(outcome.messageCount) message](inflect: true) will move to provider Trash.")
          .font(.subheadline)
      }
      if outcome.unrestorableMessageCount > 0 {
        Text(
          "^[\(outcome.unrestorableMessageCount) message](inflect: true) cannot be restored "
            + "automatically."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      ForEach(outcome.failures.indices, id: \.self) { index in
        let failure = outcome.failures[index]
        Text("\(failure.connectionDisplayName): \(failure.description)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      HStack(spacing: 8) {
        if outcome.undoBatches.isEmpty == false {
          Button("Undo", action: undo)
            .buttonStyle(.borderedProminent)
            .disabled(isUndoing)
        }
        Button("Dismiss", action: dismiss)
          .buttonStyle(.bordered)
      }
    }
    .padding(.vertical, 12)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("inbox-cleanup-outcome")
  }
}

struct InboxCleanupReviewSheet: View {
  @Bindable var model: InboxCleanupReviewModel
  let connections: [MailboxConnection]
  let cancel: () -> Void
  let confirm: () -> Void

  var body: some View {
    NavigationStack {
      List {
        if model.skippedMessageIds.isEmpty == false {
          Section {
            Label(
              "Removed ^[\(model.skippedMessageIds.count) changed message](inflect: true). "
                + "Review the updated selection before confirming again.",
              systemImage: "arrow.triangle.2.circlepath"
            )
            .foregroundStyle(.orange)
          }
        }
        ForEach(model.groups) { group in
          InboxCleanupReviewGroup(
            group: group,
            connectionName: connectionName(group.id.connectionId),
            isSelected: model.isSelected,
            setGroupSelected: { model.setSelected($0, group: group) },
            toggle: model.toggle
          )
        }
        Section {
          Text(
            "Only the selected messages will move to provider Trash after one final eligibility "
              + "check. Permanent erasure is unavailable."
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
        }
      }
      .navigationTitle("Inbox Cleanup")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", action: cancel)
            .disabled(model.isPerforming)
        }
      }
      .safeAreaInset(edge: .bottom) {
        Button(
          "Move ^[\(model.selectedMessageIds.count) Message](inflect: true) to Trash",
          role: .destructive,
          action: confirm
        )
        .buttonStyle(.borderedProminent)
        .disabled(model.selectedMessageIds.isEmpty || model.isPerforming)
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .accessibilityIdentifier("inbox-cleanup-confirm")
      }
    }
    .interactiveDismissDisabled(model.isPerforming)
  }

  private func connectionName(_ connectionId: MailboxConnectionId) -> String {
    connections.first(where: { $0.id == connectionId })?.displayName ?? "Mailbox Connection"
  }
}

private struct InboxCleanupReviewGroup: View {
  let group: InboxCleanupCandidateGroup
  let connectionName: String
  let isSelected: (InboxCleanupCandidate) -> Bool
  let setGroupSelected: (Bool) -> Void
  let toggle: (InboxCleanupCandidate) -> Void

  var body: some View {
    Section {
      ForEach(group.candidates) { candidate in
        Button {
          toggle(candidate)
        } label: {
          HStack(alignment: .top, spacing: 12) {
            Image(systemName: isSelected(candidate) ? "checkmark.circle.fill" : "circle")
              .foregroundStyle(isSelected(candidate) ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 4) {
              Text(candidate.message.subject.isEmpty ? "(No Subject)" : candidate.message.subject)
                .foregroundStyle(.primary)
              Text(
                Date(
                  timeIntervalSince1970:
                    TimeInterval(candidate.message.providerInternalDateMilliseconds) / 1_000
                ),
                format: .dateTime.year().month().day()
              )
              .font(.caption)
              .foregroundStyle(.secondary)
            }
          }
        }
        .accessibilityLabel(
          "\(isSelected(candidate) ? "Selected" : "Not selected"), \(candidate.message.subject)"
        )
      }
    } header: {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text(group.title)
          Text(connectionName)
            .font(.caption)
        }
        Spacer()
        Button(group.candidates.allSatisfy(isSelected) ? "Deselect All" : "Select All") {
          setGroupSelected(group.candidates.allSatisfy(isSelected) == false)
        }
      }
    }
  }
}
