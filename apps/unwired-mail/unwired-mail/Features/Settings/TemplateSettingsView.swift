import SwiftUI

/// Manages reusable message subjects and semantic bodies for one Mail Profile.
struct TemplateSettingsView: View {
  @Bindable var store: TemplateStore
  var navigationRequest: SettingsRouteRequest?

  @State private var editorRequest: TemplateEditorRequest?
  @State private var pendingDeletion: MailTemplate?

  var body: some View {
    Form {
      Section {
        if store.preferences.templates.isEmpty {
          ContentUnavailableView(
            "No Templates",
            systemImage: "doc.on.doc",
            description: Text("Create a reusable subject and formatted message body.")
          )
        } else {
          ForEach(store.preferences.templates) { template in
            Button {
              editorRequest = TemplateEditorRequest(template: template)
            } label: {
              TemplateSettingsRow(template: template)
            }
            .buttonStyle(.plain)
            .swipeActions {
              Button("Delete Template", role: .destructive) {
                pendingDeletion = template
              }
            }
          }
        }
      } header: {
        Text("Templates")
      } footer: {
        Text(
          "Templates synchronize end-to-end encrypted within this Mail Profile. "
            + "Recipients, attachments, signatures, and placeholders are not included."
        )
      }

      if store.isSynchronizing || store.hasPendingChanges || store.errorMessage != nil {
        Section("Synchronization") {
          if store.isSynchronizing {
            Label("Synchronizing encrypted templates…", systemImage: "arrow.triangle.2.circlepath")
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
    }
    .navigationTitle("Templates")
    .onChange(of: navigationRequest?.id) { _, _ in
      applyNavigationRequest()
    }
    .task {
      applyNavigationRequest()
    }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("New Template", systemImage: "plus") {
          editorRequest = TemplateEditorRequest()
        }
      }
    }
    .sheet(item: $editorRequest) { request in
      TemplateEditorView(request: request) { template in
        try store.saveTemplate(template, basedOn: request.template)
      }
    }
    .confirmationDialog(
      deletionTitle,
      isPresented: Binding(
        get: { pendingDeletion != nil },
        set: { if $0 == false { pendingDeletion = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Delete Template", role: .destructive) {
        guard let template = pendingDeletion else { return }
        pendingDeletion = nil
        store.deleteTemplate(template.id)
      }
      Button("Keep Template", role: .cancel) { pendingDeletion = nil }
    } message: {
      Text("Drafts already created from this template will not change.")
    }
  }

  private var deletionTitle: String {
    guard let pendingDeletion else { return "Delete this template?" }
    return "Delete “\(pendingDeletion.name)” template?"
  }

  private func applyNavigationRequest() {
    guard navigationRequest?.route?.context == .templateEditor else { return }
    editorRequest = TemplateEditorRequest()
  }
}

private struct TemplateSettingsRow: View {
  let template: MailTemplate

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 4) {
        Text(template.name)
          .foregroundStyle(.primary)
        if template.subject.isEmpty == false {
          Text(template.subject)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Text(template.document.plainText)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      Spacer()
      if template.conflictSourceId != nil {
        Label("Conflict Copy", systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
      }
      Image(systemName: "chevron.right")
        .font(.caption)
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
    }
    .contentShape(.rect)
  }
}

private struct TemplateEditorRequest: Identifiable {
  let id: String
  let template: MailTemplate?

  init(template: MailTemplate? = nil) {
    id = template?.id ?? UUID().uuidString
    self.template = template
  }
}

private struct TemplateEditorView: View {
  let request: TemplateEditorRequest
  let save: (MailTemplate, MailTemplate?) throws -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var editorModel: SemanticMessageEditorModel
  @State private var errorMessage: String?
  @State private var linkDestination = "https://"
  @State private var name: String
  @State private var showsDiscardConfirmation = false
  @State private var showsLinkEditor = false
  @State private var subject: String

  init(
    request: TemplateEditorRequest,
    save: @escaping (MailTemplate, MailTemplate?) throws -> Void
  ) {
    self.request = request
    self.save = save
    _editorModel = State(
      initialValue: SemanticMessageEditorModel(
        document: request.template?.document ?? SemanticMessageDocument(plainText: "")
      )
    )
    _name = State(initialValue: request.template?.name ?? "")
    _subject = State(initialValue: request.template?.subject ?? "")
  }

  var body: some View {
    @Bindable var editorModel = editorModel
    NavigationStack {
      VStack(spacing: 0) {
        Form {
          Section("Template") {
            TextField("Name", text: $name)
            TextField("Subject", text: $subject)
          }
          if let errorMessage {
            Section {
              Text(errorMessage)
                .foregroundStyle(.red)
            }
          }
        }
        .frame(maxHeight: 220)
        Divider()
        TextEditor(text: $editorModel.attributedText, selection: $editorModel.selection)
          .padding(16)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .accessibilityLabel("Template body")
          .onChange(of: editorModel.attributedText, editorModel.textDidChange)
        Divider()
        HStack(spacing: 8) {
          SemanticMessageFormattingControls(
            editorModel: editorModel,
            requestLink: requestLink
          )
          Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
      }
      .navigationTitle(request.template == nil ? "New Template" : "Edit Template")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", action: cancel)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save Template", action: saveTemplate)
        }
      }
      .interactiveDismissDisabled(hasChanges)
      .confirmationDialog(
        "Discard template changes?",
        isPresented: $showsDiscardConfirmation,
        titleVisibility: .visible
      ) {
        Button("Discard Changes", role: .destructive) { dismiss() }
        Button("Keep Editing", role: .cancel) {}
      }
      .alert("Add Link", isPresented: $showsLinkEditor) {
        TextField("https://example.com", text: $linkDestination)
          .textInputAutocapitalization(.never)
        Button("Add Link", action: applyLink)
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("Enter an HTTP, HTTPS, or email link for the selected text.")
      }
    }
  }

  private var candidate: MailTemplate {
    MailTemplate(
      id: request.id,
      name: name,
      subject: subject,
      document: editorModel.document,
      conflictSourceId: request.template?.conflictSourceId
    )
  }

  private var hasChanges: Bool {
    guard let original = request.template else {
      return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !editorModel.document.plainText.isEmpty
    }
    return candidate != original
  }

  private func cancel() {
    if hasChanges {
      showsDiscardConfirmation = true
    } else {
      dismiss()
    }
  }

  private func saveTemplate() {
    do {
      try save(candidate, request.template)
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func requestLink() {
    linkDestination = "https://"
    showsLinkEditor = true
  }

  private func applyLink() {
    editorModel.applyLink(linkDestination)
  }
}
