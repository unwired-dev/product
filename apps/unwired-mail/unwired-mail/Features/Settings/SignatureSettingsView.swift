import SwiftUI

struct SignatureSettingsView: View {
  let connections: [MailboxConnection]
  @Bindable var store: SignatureStore
  var navigationRequest: SettingsRouteRequest?

  @State private var editor: SignatureEditorDraft?
  @State private var pendingDeletion: MailSignature?

  var body: some View {
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
              editor = SignatureEditorDraft(signature: signature)
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

      if !connections.isEmpty {
        ForEach(connections.sorted(by: { $0.displayName < $1.displayName })) { connection in
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
        }
      }

      if store.isSynchronizing || store.hasPendingChanges || store.errorMessage != nil {
        Section("Synchronization") {
          if store.isSynchronizing {
            Label("Synchronizing encrypted signatures…", systemImage: "arrow.triangle.2.circlepath")
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
              Text(conflict.field.rawValue)
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
          }
        } header: {
          Text("Resolve Assignment Conflicts")
        } footer: {
          Text("Concurrent edits to signature content are retained as named conflict copies.")
        }
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

private struct SignatureEditorDraft: Identifiable {
  let id: String
  var body: String
  var isBold: Bool
  var isItalic: Bool
  var isUnderlined: Bool
  var link: String
  var name: String

  init(signature: MailSignature? = nil) {
    id = signature?.id ?? UUID().uuidString
    body = signature?.document.plainText ?? ""
    let run = signature?.document.runs.count == 1 ? signature?.document.runs.first : nil
    isBold = run?.isBold ?? false
    isItalic = run?.isItalic ?? false
    isUnderlined = run?.isUnderlined ?? false
    link = run?.link ?? ""
    name = signature?.name ?? ""
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
