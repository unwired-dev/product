import SwiftUI

// swiftlint:disable file_length

private enum MailComposerFocus: Hashable {
  case bcc
  case body
  case cc  // swiftlint:disable:this identifier_name
  case subject
  case to  // swiftlint:disable:this identifier_name
}

private struct MailRecipientSuggestionRequest: Equatable {
  let field: MailComposerFocus?
  let query: String
}

// swiftlint:disable:next type_body_length
struct MailShellComposer: View {
  let connections: [MailboxConnection]
  let draftDidChange: (MailShellCompositionDraft) -> Void
  let isSending: Bool
  let preferences: ComposePreferences
  let profileName: String
  let readingPreferences: ReadingPreferences
  let recipientMessages: [MailboxMessageMetadata]
  let sendingIdentities: [SendingIdentity]
  let signatures: SignaturePreferences

  @Environment(\.dismiss) private var dismiss
  @FocusState private var focusedField: MailComposerFocus?
  @State private var suggestions: [MailRecipientSuggestion] = []
  @State private var showsDiscardConfirmation = false
  @State private var showsExpandedRecipients = false
  @State private var showsMissingSubjectConfirmation = false
  @State private var showsQuotedText = false
  @State private var suggestionService: MailRecipientSuggestionService
  @State private var viewModel: MailComposerViewModel

  init(
    connections: [MailboxConnection],
    draft: MailShellCompositionDraft,
    preferences: ComposePreferences = .defaults,
    signatures: SignaturePreferences = .empty,
    isSending: Bool,
    readingPreferences: ReadingPreferences = .defaults,
    profileName: String = "Mail Profile",
    recipientMessages: [MailboxMessageMetadata] = [],
    sendingIdentities: [SendingIdentity] = [],
    suggestionService: MailRecipientSuggestionService = MailRecipientSuggestionService(),
    draftDidChange: @escaping (MailShellCompositionDraft) -> Void = { _ in },
    saveDraft: @escaping MailComposerViewModel.SaveDraft = { _ in },
    deleteDraft: @escaping MailComposerViewModel.DeleteDraft = { _ in },
    send: @escaping MailComposerViewModel.SendDraft
  ) {
    self.connections = connections
    var initialDraft = draft
    if initialDraft.signature == nil {
      initialDraft.applyDefaultSignature(from: signatures)
    }
    if let connectionId = draft.connectionId {
      initialDraft.applyInitialReadReceiptPolicy(
        readingPreferences.outgoingReadReceiptPolicy(for: connectionId)
      )
    }
    self.draftDidChange = draftDidChange
    self.isSending = isSending
    self.preferences = preferences
    self.profileName = profileName
    self.readingPreferences = readingPreferences
    self.recipientMessages = recipientMessages
    let resolvedIdentities = Self.resolvedIdentities(
      sendingIdentities,
      connections: connections
    )
    self.sendingIdentities = resolvedIdentities
    self.signatures = signatures
    if initialDraft.sendingIdentityId == nil, initialDraft.sourceMessage == nil {
      initialDraft.sendingIdentityId =
        resolvedIdentities.first {
          $0.connectionId == initialDraft.connectionId
        }?.id
    }
    _suggestionService = State(initialValue: suggestionService)
    _viewModel = State(
      initialValue: MailComposerViewModel(
        draft: initialDraft,
        presentation: preferences.presentation,
        saveDraft: saveDraft,
        deleteDraft: deleteDraft,
        sendDraft: send
      )
    )
  }

  @MainActor
  init(
    connections: [MailboxConnection],
    viewModel: MailComposerViewModel,
    preferences: ComposePreferences = .defaults,
    signatures: SignaturePreferences = .empty,
    isSending: Bool,
    readingPreferences: ReadingPreferences = .defaults,
    profileName: String = "Mail Profile",
    recipientMessages: [MailboxMessageMetadata] = [],
    sendingIdentities: [SendingIdentity] = [],
    suggestionService: MailRecipientSuggestionService = MailRecipientSuggestionService(),
    draftDidChange: @escaping (MailShellCompositionDraft) -> Void = { _ in }
  ) {
    self.connections = connections
    self.draftDidChange = draftDidChange
    self.isSending = isSending
    self.preferences = preferences
    self.profileName = profileName
    self.readingPreferences = readingPreferences
    self.recipientMessages = recipientMessages
    let resolvedIdentities = Self.resolvedIdentities(
      sendingIdentities,
      connections: connections
    )
    self.sendingIdentities = resolvedIdentities
    if viewModel.draft.sendingIdentityId == nil, viewModel.draft.sourceMessage == nil {
      viewModel.draft.sendingIdentityId =
        resolvedIdentities.first {
          $0.connectionId == viewModel.draft.connectionId
        }?.id
    }
    self.signatures = signatures
    _suggestionService = State(initialValue: suggestionService)
    _viewModel = State(initialValue: viewModel)
  }

  @ViewBuilder
  var body: some View {
    #if os(iOS)
      composer
        .presentationDetents(
          viewModel.presentation == .partial ? [.fraction(0.6)] : [.large]
        )
        .presentationDragIndicator(viewModel.presentation == .partial ? .visible : .hidden)
        .presentationBackgroundInteraction(
          viewModel.presentation == .partial ? .enabled : .disabled
        )
    #else
      composer
        .frame(minWidth: 560, minHeight: 520)
    #endif
  }

  private var composer: some View {
    @Bindable var viewModel = viewModel
    return NavigationStack {
      VStack(spacing: 0) {
        MailComposerBodyField(text: $viewModel.draft.body, focusedField: $focusedField)
        MailComposerActionBar(
          hasQuotedText: viewModel.draft.quotedText?.isEmpty == false,
          showsExpandedRecipients: $showsExpandedRecipients,
          showsQuotedText: $showsQuotedText,
          signatures: signatures,
          selectedSignatureId: selectedSignatureId
        )
        Divider()
        ScrollView {
          VStack(spacing: 12) {
            MailComposerSubjectField(
              subject: $viewModel.draft.subject,
              focusedField: $focusedField
            )
            recipientFields
            MailComposerIdentityRow(
              connections: connections,
              identities: sendingIdentities,
              profileName: profileName,
              selectedIdentityId: $viewModel.draft.sendingIdentityId
            )
            if let signature = viewModel.draft.signature {
              Text(signature.document.plainText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Selected signature: \(signature.name)")
            }
            if let quotedText = viewModel.draft.quotedText,
              !quotedText.isEmpty,
              showsQuotedText
            {
              Text(quotedText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .accessibilityLabel("Quoted text")
            }
            readReceiptControl
            saveStatus
          }
          .padding(16)
        }
      }
      .navigationTitle(viewModel.draft.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { composerToolbar }
      .task {
        viewModel.draftChanged()
        await Task.yield()
        focusedField = .body
      }
      .task(id: suggestionRequest) {
        await updateSuggestions()
      }
      .onChange(of: viewModel.draft.connectionId) { _, connectionId in
        updateConnection(connectionId)
      }
      .onChange(of: viewModel.draft.sendingIdentityId) { _, identityId in
        guard let identity = sendingIdentities.first(where: { $0.id == identityId }) else {
          return
        }
        viewModel.draft.connectionId = identity.connectionId
      }
      .onChange(of: viewModel.draft) { _, draft in
        draftDidChange(draft)
        viewModel.draftChanged()
      }
      .interactiveDismissDisabled(
        viewModel.hasUnsavedChanges || viewModel.saveState.blocksDismissal
      )
      .confirmationDialog(
        "Discard this Draft?",
        isPresented: $showsDiscardConfirmation,
        titleVisibility: .visible
      ) {
        Button("Discard Draft", role: .destructive, action: discardDraft)
        Button("Keep Editing", role: .cancel) {}
      } message: {
        Text("This removes the Draft from this device.")
      }
      .alert("Send Without a Subject?", isPresented: $showsMissingSubjectConfirmation) {
        Button("Send Without Subject", action: sendWithoutSubject)
        Button("Add Subject", role: .cancel) { focusedField = .subject }
      } message: {
        Text("The message has no subject. You can add one or send it as written.")
      }
    }
  }

  private var recipientFields: some View {
    VStack(spacing: 8) {
      MailComposerRecipientField(
        label: "To",
        text: recipientBinding(for: .to),
        focus: .to,
        focusedField: $focusedField
      )
      if showsExpandedRecipients {
        Divider()
        MailComposerRecipientField(
          label: "Cc",
          text: recipientBinding(for: .cc),
          focus: .cc,
          focusedField: $focusedField
        )
        Divider()
        MailComposerRecipientField(
          label: "Bcc",
          text: recipientBinding(for: .bcc),
          focus: .bcc,
          focusedField: $focusedField
        )
      }
      if !viewModel.draft.deliveryRecipientHeader.isEmpty,
        !viewModel.draft.recipientsAreValid
      {
        Text("Enter complete, valid email addresses before sending.")
          .font(.footnote)
          .foregroundStyle(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      if !suggestions.isEmpty {
        Divider()
        ForEach(suggestions) { suggestion in
          Button(
            action: { applySuggestion(suggestion) },
            label: {
              HStack {
                VStack(alignment: .leading, spacing: 4) {
                  if let displayName = suggestion.displayName {
                    Text(displayName)
                      .foregroundStyle(.primary)
                  }
                  Text(suggestion.emailAddress)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "plus.circle")
                  .accessibilityHidden(true)
              }
              .contentShape(.rect)
            }
          )
          .buttonStyle(.plain)
          .accessibilityLabel("Add \(suggestion.headerValue)")
        }
      }
    }
    .padding(12)
    .background(.regularMaterial, in: .rect(cornerRadius: 10))
  }

  @ViewBuilder
  private var readReceiptControl: some View {
    if selectedConnection?.capabilities.canRequestReadReceipts == true {
      if effectiveOutgoingReadReceiptPolicy == .never {
        LabeledContent("Read Receipt", value: "Not Requested")
          .foregroundStyle(.secondary)
      } else {
        Toggle(
          "Request Read Receipt",
          isOn: Binding(
            get: { viewModel.draft.requestsReadReceipt },
            set: {
              viewModel.draft.recordReadReceiptChoice($0)
            }
          )
        )
      }
    }
  }

  @ViewBuilder
  private var saveStatus: some View {
    switch viewModel.saveState {
    case .failed(let message):
      VStack(alignment: .leading, spacing: 8) {
        Label("Draft not saved", systemImage: "exclamationmark.triangle")
          .foregroundStyle(.red)
        Text(message)
          .font(.footnote)
          .foregroundStyle(.secondary)
        Button("Try Saving Again", action: viewModel.retryAutosave)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    case .pending, .saving:
      Label("Saving Draft…", systemImage: "arrow.triangle.2.circlepath")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    case .saved:
      Label("Draft saved", systemImage: "checkmark.circle")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    case .idle:
      EmptyView()
    }
  }

  @ToolbarContentBuilder
  private var composerToolbar: some ToolbarContent {
    ToolbarItem(placement: .cancellationAction) {
      Button("Close", action: closeComposer)
        .disabled(viewModel.saveState == .saving)
    }
    ToolbarItem(placement: .principal) {
      VStack(spacing: 0) {
        Text(viewModel.draft.title)
        Text("\(profileName) · \(selectedIdentity?.title ?? "Choose From address")")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    ToolbarItem(placement: .confirmationAction) {
      Button("Send", action: sendDraft)
        .accessibilityIdentifier("mail-compose-send")
        .disabled(
          isSending || !selectedConnectionCanSend || selectedIdentity == nil
            || !viewModel.canSend
        )
    }
    ToolbarItem(placement: .secondaryAction) {
      Button(
        viewModel.presentation == .partial ? "Expand Composer" : "Use Partial Composer",
        systemImage: viewModel.presentation == .partial
          ? "arrow.up.left.and.arrow.down.right"
          : "arrow.down.right.and.arrow.up.left",
        action: viewModel.togglePresentation
      )
    }
    ToolbarItem(placement: .secondaryAction) {
      Button("Discard Draft", systemImage: "trash", action: requestDiscard)
    }
  }

  private var selectedConnection: MailboxConnection? {
    guard let connectionId = viewModel.draft.connectionId else { return nil }
    return connections.first { $0.id == connectionId }
  }

  private var selectedConnectionCanSend: Bool {
    selectedConnection?.authorizationState == .authorized
      && selectedConnection?.capabilities.canSend == true
  }

  private var selectedIdentity: SendingIdentity? {
    guard let identityId = viewModel.draft.sendingIdentityId else { return nil }
    return sendingIdentities.first { $0.id == identityId }
  }

  private var effectiveOutgoingReadReceiptPolicy: OutgoingReadReceiptPolicy {
    guard let connectionId = viewModel.draft.connectionId else { return .never }
    return readingPreferences.outgoingReadReceiptPolicy(for: connectionId)
  }

  private var selectedSignatureId: Binding<String?> {
    Binding(
      get: { viewModel.draft.signature?.id },
      set: { signatureId in
        viewModel.draft.signature = signatures.signatures.first { $0.id == signatureId }
      }
    )
  }

  private var suggestionRequest: MailRecipientSuggestionRequest {
    MailRecipientSuggestionRequest(field: focusedField, query: activeRecipientQuery)
  }

  private var activeRecipientQuery: String {
    guard let focusedField else { return "" }
    return recipientText(for: focusedField)
      .split(separator: ",", omittingEmptySubsequences: false)
      .last
      .map(String.init)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  private func recipientBinding(for field: MailComposerFocus) -> Binding<String> {
    Binding(
      get: { recipientText(for: field) },
      set: { setRecipientText($0, for: field) }
    )
  }

  private func recipientText(for field: MailComposerFocus) -> String {
    switch field {
    case .bcc: viewModel.draft.bccRecipients
    case .cc: viewModel.draft.ccRecipients
    case .to: viewModel.draft.recipient
    case .body, .subject: ""
    }
  }

  private func setRecipientText(_ value: String, for field: MailComposerFocus) {
    switch field {
    case .bcc: viewModel.draft.bccRecipients = value
    case .cc: viewModel.draft.ccRecipients = value
    case .to: viewModel.draft.recipient = value
    case .body, .subject: break
    }
  }

  private func updateConnection(_ connectionId: MailboxConnectionId?) {
    guard let connectionId else {
      viewModel.draft.requestsReadReceipt = false
      viewModel.draft.signature = nil
      return
    }
    viewModel.draft.applyInitialReadReceiptPolicy(
      readingPreferences.outgoingReadReceiptPolicy(for: connectionId)
    )
    viewModel.draft.applyDefaultSignature(from: signatures)
    if viewModel.draft.sendingIdentityId.flatMap({ identityId in
      sendingIdentities.first { $0.id == identityId }
    })?.connectionId != connectionId {
      viewModel.draft.sendingIdentityId =
        sendingIdentities.first {
          $0.connectionId == connectionId
        }?.id
    }
  }

  private static func resolvedIdentities(
    _ identities: [SendingIdentity],
    connections: [MailboxConnection]
  ) -> [SendingIdentity] {
    guard identities.isEmpty else { return identities }
    return connections.compactMap { connection in
      guard RFCMailboxHeaderParser.singleMailbox(in: connection.displayName) != nil else {
        return nil
      }
      return SendingIdentity(
        address: connection.displayName,
        connectionId: connection.id,
        verification: .providerConfirmed
      )
    }
  }

  private func updateSuggestions() async {
    guard let focusedField,
      [.bcc, .cc, .to].contains(focusedField),
      !activeRecipientQuery.isEmpty
    else {
      suggestions = []
      return
    }
    suggestions = await suggestionService.suggestions(
      matching: activeRecipientQuery,
      messages: recipientMessages
    )
  }

  private func applySuggestion(_ suggestion: MailRecipientSuggestion) {
    guard let focusedField else { return }
    setRecipientText(
      MailRecipientText.applying(suggestion, to: recipientText(for: focusedField)),
      for: focusedField
    )
    suggestions = []
  }

  private func closeComposer() {
    Task {
      if await viewModel.close() { dismiss() }
    }
  }

  private func requestDiscard() {
    if viewModel.draft.hasUserState {
      showsDiscardConfirmation = true
    } else {
      discardDraft()
    }
  }

  private func discardDraft() {
    Task {
      if await viewModel.discard() { dismiss() }
    }
  }

  private func sendDraft() {
    Task {
      switch await viewModel.send() {
      case .needsSubjectConfirmation:
        showsMissingSubjectConfirmation = true
      case .sent:
        dismiss()
      case .notSent:
        break
      }
    }
  }

  private func sendWithoutSubject() {
    Task {
      if await viewModel.sendWithoutSubject() == .sent { dismiss() }
    }
  }
}

private struct MailComposerBodyField: View {
  @Binding var text: String
  let focusedField: FocusState<MailComposerFocus?>.Binding

  var body: some View {
    TextField("Message", text: $text, axis: .vertical)
      .lineLimit(8...24)
      .focused(focusedField, equals: .body)
      .padding(16)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .accessibilityIdentifier("mail-compose-body")
  }
}

private struct MailComposerActionBar: View {
  let hasQuotedText: Bool
  @Binding var showsExpandedRecipients: Bool
  @Binding var showsQuotedText: Bool
  let signatures: SignaturePreferences
  let selectedSignatureId: Binding<String?>

  var body: some View {
    HStack(spacing: 8) {
      Button("Cc and Bcc", systemImage: "person.2", action: toggleRecipients)
        .labelStyle(.iconOnly)
      if hasQuotedText {
        Button(
          showsQuotedText ? "Hide Quoted Text" : "Show Quoted Text",
          systemImage: "text.quote",
          action: toggleQuote
        )
        .labelStyle(.iconOnly)
      }
      if !signatures.signatures.isEmpty {
        Menu("Signature", systemImage: "signature") {
          Picker("Signature", selection: selectedSignatureId) {
            Text("None").tag(Optional<String>.none)
            ForEach(signatures.signatures) { signature in
              Text(signature.name).tag(Optional(signature.id))
            }
          }
        }
        .labelStyle(.iconOnly)
      }
      Spacer()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .background(.bar)
  }

  private func toggleRecipients() {
    showsExpandedRecipients.toggle()
  }

  private func toggleQuote() {
    showsQuotedText.toggle()
  }
}

private struct MailComposerIdentityRow: View {
  let connections: [MailboxConnection]
  let identities: [SendingIdentity]
  let profileName: String
  @Binding var selectedIdentityId: SendingIdentityId?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      LabeledContent("Mail Profile", value: profileName)
      Picker("From", selection: $selectedIdentityId) {
        Text("Choose a From Address")
          .tag(Optional<SendingIdentityId>.none)
        ForEach(identities) { identity in
          Text(identity.title)
            .tag(Optional(identity.id))
            .disabled(
              connections.first { $0.id == identity.connectionId }?.authorizationState
                != .authorized
                || connections.first { $0.id == identity.connectionId }?.capabilities.canSend
                  != true
            )
        }
      }
    }
    .padding(12)
    .background(.regularMaterial, in: .rect(cornerRadius: 10))
  }
}

private struct MailComposerSubjectField: View {
  @Binding var subject: String
  let focusedField: FocusState<MailComposerFocus?>.Binding

  var body: some View {
    TextField("Subject", text: $subject)
      .focused(focusedField, equals: .subject)
      .padding(12)
      .background(.regularMaterial, in: .rect(cornerRadius: 10))
      .accessibilityIdentifier("mail-compose-subject")
  }
}

private struct MailComposerRecipientField: View {
  let label: String
  @Binding var text: String
  let focus: MailComposerFocus
  let focusedField: FocusState<MailComposerFocus?>.Binding

  var body: some View {
    LabeledContent(label) {
      TextField(label, text: $text)
        .multilineTextAlignment(.leading)
        .textInputAutocapitalization(.never)
        .focused(focusedField, equals: focus)
        .accessibilityIdentifier("mail-compose-\(label.lowercased())")
    }
  }
}
