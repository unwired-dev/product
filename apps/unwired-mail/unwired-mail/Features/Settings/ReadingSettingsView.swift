import SwiftUI

// swiftlint:disable:next type_body_length
struct ReadingSettingsView: View {
  let connections: [MailboxConnection]
  @Bindable var store: ReadingPreferenceStore
  var navigationRequest: SettingsRouteRequest?

  @State private var highlightTask: Task<Void, Never>?
  @State private var highlightedField: ReadingPreferenceField?

  var body: some View {
    ScrollViewReader { proxy in
      Form {
        Section {
          Picker("Mark Opened Messages Read", selection: markReadAfter) {
            ForEach(MessageReadTiming.allCases) { timing in
              Text(timing.title).tag(timing)
            }
          }
          .id(ReadingPreferenceField.markReadAfter)
          .settingsHighlight(highlightedField == .markReadAfter)

          Toggle("Mark Read After Replying", isOn: marksReadOnReply)
            .id(ReadingPreferenceField.marksReadOnReply)
            .settingsHighlight(highlightedField == .marksReadOnReply)
          Toggle("Mark Read After Archive or Delete", isOn: marksReadOnArchiveOrDelete)
            .id(ReadingPreferenceField.marksReadOnArchiveOrDelete)
            .settingsHighlight(highlightedField == .marksReadOnArchiveOrDelete)
        } header: {
          Text("Reading")
        } footer: {
          Text(
            "Only the message you expand changes read state; opening a Thread does not mark "
              + "every message read."
          )
        }

        Section {
          Picker("Incoming Requests", selection: incomingReadReceipts) {
            ForEach(IncomingReadReceiptPolicy.allCases) { policy in
              Text(policy.title).tag(policy)
            }
          }
          .id(ReadingPreferenceField.incomingReadReceipts)
          .settingsHighlight(highlightedField == .incomingReadReceipts)

          Picker("Outgoing Requests", selection: outgoingReadReceipts) {
            ForEach(OutgoingReadReceiptPolicy.allCases) { policy in
              Text(policy.title).tag(policy)
            }
          }
          .id(ReadingPreferenceField.outgoingReadReceipts)
          .settingsHighlight(highlightedField == .outgoingReadReceipts)
        } header: {
          Text("Read Receipts")
        } footer: {
          Text("A read receipt is a request, not proof that a recipient read a message.")
        }

        ForEach(connections) { connection in
          connectionSection(connection)
        }

        if !store.conflicts.isEmpty {
          Section {
            ForEach(store.conflicts) { conflict in
              conflictView(conflict)
                .id(conflict.field)
                .settingsHighlight(highlightedField == conflict.field)
            }
          } header: {
            Text("Resolve Conflicts")
          } footer: {
            Text("Both values are preserved until you choose which one should synchronize.")
          }
        }
      }
      .onChange(of: navigationRequest?.id, initial: true) { _, _ in
        applyNavigation(navigationRequest?.route, proxy: proxy)
      }
    }
    .navigationTitle("Reading")
    .onDisappear { highlightTask?.cancel() }
  }

  private func connectionSection(_ connection: MailboxConnection) -> some View {
    let incomingField = ReadingPreferenceField.connectionIncomingReadReceipts(
      connection.id.rawValue
    )
    let outgoingField = ReadingPreferenceField.connectionOutgoingReadReceipts(
      connection.id.rawValue
    )
    return Section {
      Picker(
        "Incoming Requests",
        selection: incomingReadReceipts(connection.id)
      ) {
        Text("Use Global (\(store.preferences.incomingReadReceipts.title))")
          .tag(Optional<IncomingReadReceiptPolicy>.none)
        ForEach(IncomingReadReceiptPolicy.allCases) { policy in
          Text(policy.title).tag(Optional(policy))
        }
      }
      .disabled(!connection.capabilities.canRespondToReadReceipts)
      .id(incomingField)
      .settingsHighlight(highlightedField == incomingField)

      Picker(
        "Outgoing Requests",
        selection: outgoingReadReceipts(connection.id)
      ) {
        Text("Use Global (\(store.preferences.outgoingReadReceipts.title))")
          .tag(Optional<OutgoingReadReceiptPolicy>.none)
        ForEach(OutgoingReadReceiptPolicy.allCases) { policy in
          Text(policy.title).tag(Optional(policy))
        }
      }
      .disabled(!connection.capabilities.canRequestReadReceipts)
      .id(outgoingField)
      .settingsHighlight(highlightedField == outgoingField)
    } header: {
      Text(connection.displayName)
    } footer: {
      if !connection.capabilities.canRespondToReadReceipts
        && !connection.capabilities.canRequestReadReceipts
      {
        Text("This Mailbox Connection does not support read receipts.")
      } else if !connection.capabilities.canRespondToReadReceipts {
        Text(
          "This Mailbox Connection can request receipts but cannot respond to incoming requests."
        )
      } else if !connection.capabilities.canRequestReadReceipts {
        Text("This Mailbox Connection can respond to requests but cannot request receipts.")
      }
    }
  }

  private func conflictView(_ conflict: ReadingPreferenceConflict) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title(for: conflict.field))
        .font(.headline)
      LabeledContent("This Device", value: conflict.localValue.title)
      LabeledContent("Synced", value: conflict.remoteValue.title)
      HStack {
        Button("Use This Device") {
          store.resolveConflict(conflict.field, useLocalValue: true)
        }
        .buttonStyle(.borderedProminent)
        Button("Use Synced") {
          store.resolveConflict(conflict.field, useLocalValue: false)
        }
        .buttonStyle(.bordered)
      }
    }
    .padding(.vertical, 4)
  }

  private var markReadAfter: Binding<MessageReadTiming> {
    Binding(get: { store.preferences.markReadAfter }, set: store.setMarkReadAfter)
  }

  private var marksReadOnReply: Binding<Bool> {
    Binding(get: { store.preferences.marksReadOnReply }, set: store.setMarksReadOnReply)
  }

  private var marksReadOnArchiveOrDelete: Binding<Bool> {
    Binding(
      get: { store.preferences.marksReadOnArchiveOrDelete },
      set: store.setMarksReadOnArchiveOrDelete
    )
  }

  private var incomingReadReceipts: Binding<IncomingReadReceiptPolicy> {
    Binding(
      get: { store.preferences.incomingReadReceipts },
      set: store.setIncomingReadReceipts
    )
  }

  private var outgoingReadReceipts: Binding<OutgoingReadReceiptPolicy> {
    Binding(
      get: { store.preferences.outgoingReadReceipts },
      set: store.setOutgoingReadReceipts
    )
  }

  private func incomingReadReceipts(
    _ connectionId: MailboxConnectionId
  ) -> Binding<IncomingReadReceiptPolicy?> {
    Binding(
      get: {
        store.preferences.connectionOverrides[connectionId.rawValue]?.incomingReadReceipts
      },
      set: { store.setIncomingReadReceipts($0, connectionId: connectionId) }
    )
  }

  private func outgoingReadReceipts(
    _ connectionId: MailboxConnectionId
  ) -> Binding<OutgoingReadReceiptPolicy?> {
    Binding(
      get: {
        store.preferences.connectionOverrides[connectionId.rawValue]?.outgoingReadReceipts
      },
      set: { store.setOutgoingReadReceipts($0, connectionId: connectionId) }
    )
  }

  private func title(for field: ReadingPreferenceField) -> String {
    switch field {
    case .markReadAfter:
      "Mark Opened Messages Read"
    case .marksReadOnReply:
      "Mark Read After Replying"
    case .marksReadOnArchiveOrDelete:
      "Mark Read After Archive or Delete"
    case .incomingReadReceipts:
      "Incoming Read Receipts"
    case .outgoingReadReceipts:
      "Outgoing Read Receipts"
    case .connectionIncomingReadReceipts(let connectionId):
      "\(connectionTitle(connectionId)): Incoming Read Receipts"
    case .connectionOutgoingReadReceipts(let connectionId):
      "\(connectionTitle(connectionId)): Outgoing Read Receipts"
    }
  }

  private func connectionTitle(_ connectionId: String) -> String {
    connections.first { $0.id.rawValue == connectionId }?.displayName ?? connectionId
  }

  private func applyNavigation(_ route: SettingsRoute?, proxy: ScrollViewProxy) {
    let field: ReadingPreferenceField?
    switch route?.context {
    case .preferenceConflict(let rawField):
      field = decodeConflictField(rawField)
    case .readReceipt(let connectionId, let receiptField):
      switch (connectionId, receiptField) {
      case (.some(let connectionId), .incoming):
        field = .connectionIncomingReadReceipts(connectionId)
      case (.some(let connectionId), .outgoing):
        field = .connectionOutgoingReadReceipts(connectionId)
      case (.none, .incoming):
        field = .incomingReadReceipts
      case (.none, .outgoing):
        field = .outgoingReadReceipts
      }
    default:
      field = nil
    }
    guard let field else { return }

    withAnimation {
      proxy.scrollTo(field, anchor: .center)
      highlightedField = field
    }
    highlightTask?.cancel()
    highlightTask = Task {
      try? await Task.sleep(for: .seconds(1.5))
      guard !Task.isCancelled else { return }
      withAnimation { highlightedField = nil }
    }
  }

  private func decodeConflictField(_ rawField: String) -> ReadingPreferenceField? {
    switch rawField {
    case "incomingReadReceipts":
      .incomingReadReceipts
    case "markReadAfter":
      .markReadAfter
    case "marksReadOnArchiveOrDelete":
      .marksReadOnArchiveOrDelete
    case "marksReadOnReply":
      .marksReadOnReply
    case "outgoingReadReceipts":
      .outgoingReadReceipts
    default:
      if rawField.hasPrefix("connectionIncomingReadReceipts:") {
        .connectionIncomingReadReceipts(
          String(rawField.dropFirst("connectionIncomingReadReceipts:".count))
        )
      } else if rawField.hasPrefix("connectionOutgoingReadReceipts:") {
        .connectionOutgoingReadReceipts(
          String(rawField.dropFirst("connectionOutgoingReadReceipts:".count))
        )
      } else {
        nil
      }
    }
  }
}
