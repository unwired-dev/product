import SwiftUI

// swiftlint:disable file_length

struct SignatureSettingsView: View {
  let connections: [MailboxConnection]
  @Bindable var store: SignatureStore
  var navigationRequest: SettingsRouteRequest?

  @State private var editor: SignatureEditorDraft?
  @State private var highlightTask: Task<Void, Never>?
  @State private var highlightedAnchor: SignatureSettingsAnchor?
  @State private var pendingDeletion: MailSignature?
  @State private var unsupportedFormattedSignatureName: String?

  var body: some View {
    ScrollViewReader { proxy in
      Form {
        Section {
          if store.preferences.signatures.isEmpty {
            ContentUnavailableView(
              "No Signatures",
              systemImage: "signature",
              description: Text(
                "Create a formatted signature, then assign it to a Mailbox Connection.")
            )
          } else {
            ForEach(store.preferences.signatures) { signature in
              Button {
                if let draft = SignatureEditorDraft(signature: signature) {
                  editor = draft
                } else {
                  unsupportedFormattedSignatureName = signature.name
                }
              } label: {
                HStack {
                  VStack(alignment: .leading, spacing: 3) {
                    Text(signature.name)
                      .foregroundStyle(.primary)
                    Text(signature.document.plainText)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      .lineLimit(2)
                  }
                  Spacer()
                  if signature.conflictSourceId != nil {
                    Label("Conflict Copy", systemImage: "exclamationmark.triangle.fill")
                      .font(.caption)
                      .foregroundStyle(.orange)
                  }
                  Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .swipeActions {
                Button("Delete", role: .destructive) {
                  pendingDeletion = signature
                }
              }
            }
          }
        } header: {
          Text("Signatures")
        } footer: {
          Text(
            "Signature text and assignments synchronize end-to-end encrypted. "
              + "Remote images and externally hosted assets are not supported."
          )
        }
        .id(SignatureSettingsAnchor.signatures)
        .settingsHighlight(highlightedAnchor == .signatures)

        if !connections.isEmpty {
          ForEach(
            connections.sorted {
              $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
          ) { connection in
            Section(connection.displayName) {
              Picker(
                "New Messages",
                selection: defaultBinding(connection.id, context: .newMessage)
              ) {
                signatureOptions
              }
              Picker(
                "Replies & Forwards",
                selection: defaultBinding(connection.id, context: .replyOrForward)
              ) {
                signatureOptions
              }
            }
            .id(SignatureSettingsAnchor.connection(connection.id.rawValue))
            .settingsHighlight(
              highlightedAnchor == .connection(connection.id.rawValue)
            )
          }
        }

        if store.isSynchronizing || store.hasPendingChanges || store.errorMessage != nil {
          Section("Synchronization") {
            if store.isSynchronizing {
              Label(
                "Synchronizing encrypted signatures…",
                systemImage: "arrow.triangle.2.circlepath"
              )
            } else if store.hasPendingChanges {
              Label("Changes are saved on this device and waiting to sync.", systemImage: "clock")
            }
            if let errorMessage = store.errorMessage {
              Text(errorMessage)
                .foregroundStyle(.red)
              Button("Try Again") {
                Task { await store.synchronize() }
              }
              .disabled(store.isSynchronizing)
            }
          }
        }

        if !store.conflicts.isEmpty {
          Section {
            ForEach(store.conflicts) { conflict in
              VStack(alignment: .leading, spacing: 8) {
                Text(title(for: conflict.field))
                  .font(.headline)
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
              .id(SignatureSettingsAnchor.conflict(conflict.field))
              .settingsHighlight(highlightedAnchor == .conflict(conflict.field))
            }
          } header: {
            Text("Resolve Assignment Conflicts")
          } footer: {
            Text("Concurrent edits to signature content are retained as named conflict copies.")
          }
        }
      }
      .onChange(of: navigationRequest?.id, initial: true) { _, _ in
        applyNavigation(navigationRequest?.route, proxy: proxy)
      }
      .onChange(of: connections.map(\.id)) { _, _ in
        applyNavigation(navigationRequest?.route, proxy: proxy)
      }
    }
    .navigationTitle("Signatures")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          editor = SignatureEditorDraft()
        } label: {
          Label("New Signature", systemImage: "plus")
        }
      }
    }
    .sheet(item: $editor) { draft in
      SignatureEditorView(draft: draft) { signature in
        try store.saveSignature(signature)
      }
    }
    .alert(
      "Formatting Not Supported",
      isPresented: Binding(
        get: { unsupportedFormattedSignatureName != nil },
        set: { if !$0 { unsupportedFormattedSignatureName = nil } }
      )
    ) {
      Button("OK") { unsupportedFormattedSignatureName = nil }
    } message: {
      Text(
        "\(unsupportedFormattedSignatureName ?? "This signature") uses multiple formatting "
          + "styles. Editing it here could discard formatting, so it cannot be edited yet."
      )
    }
    .confirmationDialog(
      "Delete this signature?",
      isPresented: Binding(
        get: { pendingDeletion != nil },
        set: { if !$0 { pendingDeletion = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Delete", role: .destructive) {
        guard let signature = pendingDeletion else { return }
        pendingDeletion = nil
        store.deleteSignature(signature.id)
      }
      Button("Cancel", role: .cancel) { pendingDeletion = nil }
    } message: {
      Text("Its new-message and reply/forward assignments will also be removed.")
    }
    .onDisappear {
      highlightTask?.cancel()
    }
  }

  @ViewBuilder
  private var signatureOptions: some View {
    Text("None").tag(Optional<String>.none)
    ForEach(store.preferences.signatures) { signature in
      Text(signature.name).tag(Optional(signature.id))
    }
  }

  private func defaultBinding(
    _ connectionId: MailboxConnectionId,
    context: SignatureComposeContext
  ) -> Binding<String?> {
    Binding(
      get: {
        let assignment = store.preferences.assignments[connectionId.rawValue]
        return context == .newMessage
          ? assignment?.newMessageSignatureId
          : assignment?.replyOrForwardSignatureId
      },
      set: { store.setDefault($0, connectionId: connectionId, context: context) }
    )
  }
}

extension SignatureSettingsView {
  private func title(for field: SignaturePreferenceField) -> String {
    switch field.kind {
    case .newMessage(let connectionId):
      return "\(connectionTitle(connectionId)): New Messages"
    case .replyOrForward(let connectionId):
      return "\(connectionTitle(connectionId)): Replies & Forwards"
    case .signature(let id):
      return store.preferences.signatures.first { $0.id == id }?.name ?? "Signature"
    }
  }

  private func connectionTitle(_ connectionId: String) -> String {
    connections.first { $0.id.rawValue == connectionId }?.displayName ?? "Mailbox Connection"
  }

  private func applyNavigation(
    _ route: SettingsRoute?,
    proxy: ScrollViewProxy
  ) {
    let anchor: SignatureSettingsAnchor
    switch route?.context {
    case .missingSignature(let connectionId):
      if let connectionId, connections.contains(where: { $0.id.rawValue == connectionId }) {
        anchor = .connection(connectionId)
      } else {
        anchor = .signatures
      }
    case .preferenceConflict(let rawField):
      anchor = .conflict(SignaturePreferenceField(rawValue: rawField))
    case nil where route?.destination == .signatures:
      anchor = .signatures
    default:
      return
    }

    withAnimation {
      proxy.scrollTo(anchor, anchor: .center)
      highlightedAnchor = anchor
    }
    highlightTask?.cancel()
    highlightTask = Task {
      try? await Task.sleep(for: .seconds(1.5))
      guard !Task.isCancelled else { return }
      withAnimation {
        highlightedAnchor = nil
      }
    }
  }
}

private enum SignatureSettingsAnchor: Hashable {
  case conflict(SignaturePreferenceField)
  case connection(String)
  case signatures
}

private struct SignatureEditorDraft: Identifiable {
  let id: String
  var body: String
  var isBold: Bool
  var isItalic: Bool
  var isUnderlined: Bool
  var link: String
  var name: String

  init() {
    id = UUID().uuidString
    body = ""
    isBold = false
    isItalic = false
    isUnderlined = false
    link = ""
    name = ""
  }

  init?(signature: MailSignature) {
    guard signature.document.runs.count == 1, let run = signature.document.runs.first else {
      return nil
    }
    id = signature.id
    body = signature.document.plainText
    isBold = run.isBold
    isItalic = run.isItalic
    isUnderlined = run.isUnderlined
    link = run.link ?? ""
    name = signature.name
  }

  var signature: MailSignature {
    MailSignature(
      id: id,
      name: name,
      document: SignatureDocument(
        text: body,
        isBold: isBold,
        isItalic: isItalic,
        isUnderlined: isUnderlined,
        link: link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          ? nil
          : link.trimmingCharacters(in: .whitespacesAndNewlines)
      )
    )
  }
}

private struct SignatureEditorView: View {
  @State var draft: SignatureEditorDraft
  let save: (MailSignature) throws -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var errorMessage: String?
  @State private var showsDiscardConfirmation = false

  var body: some View {
    NavigationStack {
      Form {
        Section("Signature") {
          TextField("Name", text: $draft.name)
          TextEditor(text: $draft.body)
            .frame(minHeight: 140)
        }
        Section("Formatting") {
          Toggle("Bold", isOn: $draft.isBold)
          Toggle("Italic", isOn: $draft.isItalic)
          Toggle("Underline", isOn: $draft.isUnderlined)
          TextField("Link (optional)", text: $draft.link)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
        Section {
          Text(draft.signature.document.plainText)
            .bold(draft.isBold)
            .italic(draft.isItalic)
            .underline(draft.isUnderlined)
        } header: {
          Text("Plain-Text Alternative")
        } footer: {
          Text("Formatting is omitted from plain-text delivery; the visible text is preserved.")
        }
        if let errorMessage {
          Section {
            Text(errorMessage)
              .foregroundStyle(.red)
          }
        }
      }
      .navigationTitle("Edit Signature")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { showsDiscardConfirmation = true }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            do {
              try save(draft.signature)
              dismiss()
            } catch {
              errorMessage = error.localizedDescription
            }
          }
        }
      }
      .interactiveDismissDisabled()
      .confirmationDialog(
        "Discard signature changes?",
        isPresented: $showsDiscardConfirmation,
        titleVisibility: .visible
      ) {
        Button("Discard Changes", role: .destructive) { dismiss() }
        Button("Keep Editing", role: .cancel) {}
      }
    }
  }
}
