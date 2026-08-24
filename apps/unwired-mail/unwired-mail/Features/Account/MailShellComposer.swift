import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

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
  let mailAssistanceViewModel: MailAssistanceViewModel?
  let preferences: ComposePreferences
  let profileName: String
  let readingPreferences: ReadingPreferences
  let recipientMessages: [MailboxMessageMetadata]
  let sendingIdentities: [SendingIdentity]
  let signatures: SignaturePreferences
  let templates: TemplatePreferences

  @Environment(\.dismiss) private var dismiss
  @FocusState private var focusedField: MailComposerFocus?
  @State private var editorModel: SemanticMessageEditorModel
  @State private var assetErrorMessage: String?
  @State private var composeAssistancePresentation: ComposeAssistancePresentation?
  @State private var linkDestination = "https://"
  @State private var sendLaterRequest: SendLaterRequest?
  @State private var selectedPhoto: PhotosPickerItem?
  @State private var suggestions: [MailRecipientSuggestion] = []
  @State private var showsDiscardConfirmation = false
  @State private var showsExpandedRecipients = false
  @State private var showsMissingSubjectConfirmation = false
  @State private var showsLinkEditor = false
  @State private var showsFileImporter = false
  @State private var showsQuotedText = false
  @State private var suggestionService: MailRecipientSuggestionService
  @State private var viewModel: MailComposerViewModel

  init(
    connections: [MailboxConnection],
    draft: MailShellCompositionDraft,
    preferences: ComposePreferences = .defaults,
    signatures: SignaturePreferences = .empty,
    templates: TemplatePreferences = .empty,
    isSending: Bool,
    mailAssistanceViewModel: MailAssistanceViewModel? = nil,
    readingPreferences: ReadingPreferences = .defaults,
    profileName: String = "Mail Profile",
    recipientMessages: [MailboxMessageMetadata] = [],
    sendingIdentities: [SendingIdentity] = [],
    suggestionService: MailRecipientSuggestionService = MailRecipientSuggestionService(),
    draftDidChange: @escaping (MailShellCompositionDraft) -> Void = { _ in },
    saveDraft: @escaping MailComposerViewModel.SaveDraft = { _ in },
    deleteDraft: @escaping MailComposerViewModel.DeleteDraft = { _ in },
    reminderOwnerDeviceId: String = "local-device",
    cancelReminder: @escaping MailComposerViewModel.CancelReminder = { _, _ in },
    scheduleReminder: @escaping MailComposerViewModel.ScheduleReminder = { _ in .unavailable },
    scheduleSend: @escaping MailComposerViewModel.ScheduleSend = { _, _, _ in false },
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
    self.mailAssistanceViewModel = mailAssistanceViewModel
    self.preferences = preferences
    self.profileName = profileName
    self.readingPreferences = readingPreferences
    self.recipientMessages = recipientMessages
    self.sendingIdentities = sendingIdentities
    self.signatures = signatures
    self.templates = templates
    _suggestionService = State(initialValue: suggestionService)
    _editorModel = State(
      initialValue: SemanticMessageEditorModel(document: initialDraft.document)
    )
    _viewModel = State(
      initialValue: MailComposerViewModel(
        draft: initialDraft,
        presentation: preferences.presentation,
        reminderOwnerDeviceId: reminderOwnerDeviceId,
        saveDraft: saveDraft,
        deleteDraft: deleteDraft,
        cancelReminder: cancelReminder,
        scheduleReminder: scheduleReminder,
        scheduleSend: scheduleSend,
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
    templates: TemplatePreferences = .empty,
    isSending: Bool,
    mailAssistanceViewModel: MailAssistanceViewModel? = nil,
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
    self.mailAssistanceViewModel = mailAssistanceViewModel
    self.preferences = preferences
    self.profileName = profileName
    self.readingPreferences = readingPreferences
    self.recipientMessages = recipientMessages
    self.sendingIdentities = sendingIdentities
    self.signatures = signatures
    self.templates = templates
    _suggestionService = State(initialValue: suggestionService)
    _editorModel = State(
      initialValue: SemanticMessageEditorModel(document: viewModel.draft.document)
    )
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
        MailComposerBodyField(editorModel: editorModel, focusedField: $focusedField)
          .dropDestination(for: Data.self) { items, _ in
            addDroppedImages(items)
            return !items.isEmpty
          }
          .dropDestination(for: URL.self) { urls, _ in
            importFiles(.success(urls))
            return !urls.isEmpty
          }
        MailComposerActionBar(
          editorModel: editorModel,
          hasQuotedText: viewModel.draft.quotedText?.isEmpty == false,
          requestFile: { showsFileImporter = true },
          requestLink: requestLink,
          showsFormattingToolbar: preferences.showsFormattingToolbar,
          showsExpandedRecipients: $showsExpandedRecipients,
          showsQuotedText: $showsQuotedText,
          signatures: signatures,
          selectedSignatureId: selectedSignatureId,
          templates: templates,
          applyTemplate: applyTemplate,
          requestAssistance: mailAssistanceViewModel == nil ? nil : requestComposeAssistance
        )
        Divider()
        ScrollView {
          composerDetails
        }
      }
      .navigationTitle(viewModel.draft.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { composerToolbar }
      .fileImporter(
        isPresented: $showsFileImporter,
        allowedContentTypes: [.data],
        allowsMultipleSelection: true,
        onCompletion: importFiles
      )
      .sheet(item: $composeAssistancePresentation) { presentation in
        if let mailAssistanceViewModel {
          ComposeAssistanceView(
            presentation: presentation,
            assistanceViewModel: mailAssistanceViewModel,
            currentInputVersion: {
              ComposeAssistanceRequestBuilder.inputVersion(
                document: editorModel.document,
                target: presentation.target,
                subject: viewModel.draft.subject,
                recipientDisplayNames: recipientDisplayNames
              )
            },
            applyDocument: { document, application, target in
              editorModel.applyAssistanceDocument(
                document,
                application: application,
                target: target
              )
            },
            applySubject: { subject in
              viewModel.draft.subject = subject
            }
          )
        }
      }
      .onChange(of: selectedPhoto) { _, item in
        guard let item else { return }
        Task { await importPhoto(item) }
      }
      .task {
        viewModel.draftChanged()
        await Task.yield()
        guard focusedField == nil else { return }
        focusedField = .body
      }
      .task(id: suggestionRequest) {
        await updateSuggestions()
      }
      .onChange(of: viewModel.draft.connectionId) { _, connectionId in
        updateConnection(connectionId)
      }
      .onChange(of: viewModel.draft.sendingIdentityId) { _, identityId in
        updateSendingIdentity(identityId)
      }
      .onChange(of: viewModel.draft) { _, draft in
        draftDidChange(draft)
        viewModel.draftChanged()
      }
      .onChange(of: editorModel.document) { _, document in
        guard viewModel.draft.document != document else { return }
        viewModel.draft.document = document
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
      .alert("Add Link", isPresented: $showsLinkEditor) {
        TextField("https://example.com", text: $linkDestination)
          .textInputAutocapitalization(.never)
        Button("Add Link", action: applyLink)
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("Enter an HTTP, HTTPS, or email link for the selected text.")
      }
      .sheet(item: $sendLaterRequest) { _ in
        SendLaterSheet(
          existingReminder: viewModel.draft.sendReminder,
          canAutomaticallySend: canScheduleSend,
          scheduleAutomatically: { dueAt, timeZone in
            let scheduled = await viewModel.scheduleSend(
              at: dueAt,
              timeZoneIdentifier: timeZone
            )
            if scheduled { dismiss() }
            return scheduled
          },
          schedule: { dueAt, timeZone in
            await viewModel.remind(at: dueAt, timeZoneIdentifier: timeZone)
          }
        )
      }
    }
  }

  private var composerDetails: some View {
    @Bindable var viewModel = viewModel
    return VStack(spacing: 12) {
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
        MailComposerSignatureSummary(signature: signature)
      }
      if let reminder = viewModel.draft.sendReminder {
        MailComposerReminderSummary(
          notificationState: viewModel.reminderState,
          reminder: reminder
        )
      }
      MailComposerAssetList(
        assets: viewModel.draft.assets,
        remove: removeAsset,
        toggleDisposition: toggleAssetDisposition
      )
      if let assetStatusMessage {
        MailComposerAssetStatus(message: assetStatusMessage)
      }
      if exceedsKnownTransferLimit,
        viewModel.draft.assets.contains(where: {
          $0.mediaType.hasPrefix("image/")
        })
      {
        Button("Compress Images", action: compressImages)
          .frame(maxWidth: .infinity, alignment: .leading)
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

  private func updateSendingIdentity(_ identityId: SendingIdentityId?) {
    guard let identity = sendingIdentities.first(where: { $0.id == identityId }) else { return }
    viewModel.draft.connectionId = identity.connectionId
  }

  private func removeAsset(_ id: UUID) {
    editorModel.removeInlineAsset(id)
    viewModel.draft.removeAsset(id)
  }

  private func toggleAssetDisposition(_ id: UUID) {
    guard let asset = viewModel.draft.assets.first(where: { $0.id == id }) else { return }
    if asset.disposition == .inline {
      editorModel.removeInlineAsset(id)
    } else {
      editorModel.insertInlineAsset(id)
    }
    viewModel.draft.toggleAssetDisposition(id)
  }

  private func compressImages() {
    viewModel.draft.compressImages()
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
      MailComposerSendButton(
        canSendLater: viewModel.canCreateSendReminder,
        isSendEnabled: isSendEnabled,
        send: sendDraft,
        sendLater: openSendLater
      )
    }
    ToolbarItem(placement: .secondaryAction) {
      Button("Send Later", systemImage: "clock", action: openSendLater)
        .disabled(!viewModel.canCreateSendReminder)
        .keyboardShortcut("l", modifiers: [.command, .shift])
    }
    ToolbarItem(placement: .secondaryAction) {
      PhotosPicker(selection: $selectedPhoto, matching: .images) {
        Label("Attach Photo", systemImage: "photo")
      }
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

  private var isSendEnabled: Bool {
    !isSending && selectedConnectionCanSend && selectedIdentity != nil
      && viewModel.canSend && !exceedsKnownTransferLimit
  }

  private var canScheduleSend: Bool {
    isSendEnabled && selectedConnection?.providerId == .gmail
      && viewModel.draft.kind != .editing
  }

  private func openSendLater() {
    guard viewModel.canCreateSendReminder else { return }
    sendLaterRequest = SendLaterRequest()
  }

  private var selectedConnectionCanSend: Bool {
    selectedConnection?.authorizationState == .authorized
      && selectedConnection?.capabilities.canSend == true
  }

  private var selectedIdentity: SendingIdentity? {
    guard
      let identityId = viewModel.draft.sendingIdentityId,
      let connectionId = viewModel.draft.connectionId,
      let identity = sendingIdentities.first(where: { $0.id == identityId }),
      identity.connectionId == connectionId
    else { return nil }
    return identity
  }

  private var estimatedTransferByteCount: Int {
    MailDraftTransferBudget.estimatedByteCount(
      body: viewModel.draft.deliveryBody,
      htmlBody: viewModel.draft.deliveryHTML,
      assets: viewModel.draft.assets
    )
  }

  private var exceedsKnownTransferLimit: Bool {
    guard let providerId = selectedConnection?.providerId,
      let limit = MailDraftTransferBudget.knownLimit(for: providerId)
    else { return false }
    return estimatedTransferByteCount > limit
  }

  private var assetStatusMessage: String? {
    if let assetErrorMessage { return assetErrorMessage }
    if viewModel.draft.omittedForwardAttachmentCount > 0 {
      let count = viewModel.draft.omittedForwardAttachmentCount
      return
        "\(count) source attachment\(count == 1 ? "" : "s") was not included because it is not downloaded."
    }
    if !viewModel.draft.assetsAreReady {
      return "Download every Draft asset before sending."
    }
    if exceedsKnownTransferLimit {
      return "This message is too large for the selected Mailbox Connection. Remove an attachment."
    }
    guard !viewModel.draft.assets.isEmpty,
      let providerId = selectedConnection?.providerId,
      MailDraftTransferBudget.knownLimit(for: providerId) == nil
    else { return nil }
    let size = estimatedTransferByteCount.formatted(.byteCount(style: .file))
    return "Estimated message size: \(size). The provider limit is unknown."
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
    viewModel.draft.sendingIdentityId = Self.validatedSendingIdentityId(
      viewModel.draft.sendingIdentityId,
      for: connectionId,
      among: sendingIdentities
    )
  }

  static func validatedSendingIdentityId(
    _ identityId: SendingIdentityId?,
    for connectionId: MailboxConnectionId,
    among identities: [SendingIdentity]
  ) -> SendingIdentityId? {
    guard
      let identityId,
      let identity = identities.first(where: { $0.id == identityId }),
      identity.connectionId == connectionId
    else { return nil }
    return identity.id
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

  private func requestLink() {
    linkDestination = "https://"
    showsLinkEditor = true
  }

  private func requestComposeAssistance() {
    guard let mailAssistanceViewModel else { return }
    mailAssistanceViewModel.discardPreview()
    composeAssistancePresentation = ComposeAssistancePresentation(
      localeIdentifier: Locale.current.identifier,
      profileId: mailAssistanceViewModel.activeProfileId,
      recipientDisplayNames: recipientDisplayNames,
      subject: viewModel.draft.subject,
      target: editorModel.composeAssistanceTarget()
    )
  }

  private var recipientDisplayNames: [String] {
    [viewModel.draft.recipient, viewModel.draft.ccRecipients]
      .flatMap { RFCMailboxHeaderParser.mailboxes(in: $0) ?? [] }
      .compactMap(\.displayName)
  }

  private func applyLink() {
    editorModel.applyLink(linkDestination)
  }

  private func applyTemplate(_ template: MailTemplate) {
    viewModel.draft.applyTemplateSubjectIfEmpty(template)
    editorModel.insertAtEnd(template.document)
  }

  private func addDroppedImages(_ items: [Data]) {
    for (index, data) in items.enumerated() {
      let asset = MailDraftAsset(
        data: data,
        filename: "Inline Image \(index + 1).png",
        mediaType: UTType.png.preferredMIMEType ?? "image/png",
        disposition: .inline
      )
      viewModel.draft.addAsset(asset)
      editorModel.insertInlineAsset(asset.id)
    }
  }

  private func importFiles(_ result: Result<[URL], Error>) {
    do {
      for url in try result.get() {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.contentTypeKey])
        viewModel.draft.addAsset(
          MailDraftAsset(
            data: try Data(contentsOf: url),
            filename: url.lastPathComponent,
            mediaType: values.contentType?.preferredMIMEType ?? "application/octet-stream"
          )
        )
      }
      assetErrorMessage = nil
    } catch {
      assetErrorMessage = "Can't attach the selected file. Choose a local file and try again."
    }
  }

  private func importPhoto(_ item: PhotosPickerItem) async {
    do {
      guard let data = try await item.loadTransferable(type: Data.self) else {
        assetErrorMessage = "Can't attach the selected photo. Choose another photo."
        return
      }
      viewModel.draft.addAsset(
        MailDraftAsset(
          data: data,
          filename: "Photo.heic",
          mediaType: item.supportedContentTypes.first?.preferredMIMEType ?? "image/heic"
        )
      )
      assetErrorMessage = nil
    } catch {
      assetErrorMessage = "Can't attach the selected photo. Choose another photo."
    }
    selectedPhoto = nil
  }
}

private struct MailComposerSignatureSummary: View {
  let signature: MailSignature

  var body: some View {
    Text(signature.document.plainText)
      .font(.callout)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityLabel("Selected signature: \(signature.name)")
  }
}

private struct MailComposerAssetStatus: View {
  let message: String

  var body: some View {
    Label(message, systemImage: "exclamationmark.triangle")
      .font(.footnote)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct MailComposerBodyField: View {
  @Bindable var editorModel: SemanticMessageEditorModel
  let focusedField: FocusState<MailComposerFocus?>.Binding

  var body: some View {
    TextEditor(text: $editorModel.attributedText, selection: $editorModel.selection)
      .focused(focusedField, equals: .body)
      .padding(16)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .accessibilityIdentifier("mail-compose-body")
      .accessibilityLabel("Message")
      .onChange(of: editorModel.attributedText, editorModel.textDidChange)
      .contextMenu {
        ForEach(SemanticMessageBlockCommand.allCases) { command in
          Button(command.title, systemImage: command.systemImage) {
            editorModel.applyBlock(command)
          }
        }
      }
  }
}

private struct MailComposerActionBar: View {
  @Bindable var editorModel: SemanticMessageEditorModel
  let hasQuotedText: Bool
  let requestFile: () -> Void
  let requestLink: () -> Void
  let showsFormattingToolbar: Bool
  @Binding var showsExpandedRecipients: Bool
  @Binding var showsQuotedText: Bool
  let signatures: SignaturePreferences
  let selectedSignatureId: Binding<String?>
  let templates: TemplatePreferences
  let applyTemplate: (MailTemplate) -> Void
  let requestAssistance: (() -> Void)?

  var body: some View {
    HStack(spacing: 8) {
      Button("Attach File", systemImage: "paperclip", action: requestFile)
        .labelStyle(.iconOnly)
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
      if !templates.templates.isEmpty {
        Menu("Insert Template", systemImage: "doc.on.doc") {
          ForEach(templates.templates) { template in
            Button(template.name) {
              applyTemplate(template)
            }
          }
        }
        .labelStyle(.iconOnly)
      }
      if showsFormattingToolbar {
        Divider()
        SemanticMessageFormattingControls(
          editorModel: editorModel,
          requestLink: requestLink
        )
      }
      if let requestAssistance {
        Button("Compose Assistance", systemImage: "sparkles", action: requestAssistance)
          .labelStyle(.iconOnly)
      }
      MailComposerKeyboardCommands(editorModel: editorModel, requestLink: requestLink)
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

struct SemanticMessageFormattingControls: View {
  @Bindable var editorModel: SemanticMessageEditorModel
  let requestLink: () -> Void

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 4) {
        inlineButton(.bold)
        inlineButton(.italic)
        inlineButton(.underline)
        formattingMenu
      }
      compactFormattingMenu
    }
  }

  private var formattingMenu: some View {
    Menu("More Formatting", systemImage: "ellipsis") {
      inlineButton(.strikethrough)
      inlineButton(.code)
      Button("Add Link", systemImage: "link", action: requestLink)
      Divider()
      blockCommands
      Divider()
      historyCommands
    }
    .labelStyle(.iconOnly)
    .frame(minWidth: 44, minHeight: 44)
  }

  private var compactFormattingMenu: some View {
    Menu("Formatting", systemImage: "textformat") {
      ForEach(SemanticMessageInlineCommand.allCases) { command in
        inlineButton(command)
      }
      Button("Add Link", systemImage: "link", action: requestLink)
      Divider()
      blockCommands
      Divider()
      historyCommands
    }
    .labelStyle(.iconOnly)
    .frame(minWidth: 44, minHeight: 44)
  }

  @ViewBuilder
  private var blockCommands: some View {
    Menu("Block Style", systemImage: "paragraphsign") {
      ForEach(SemanticMessageBlockCommand.allCases) { command in
        Button(command.title, systemImage: command.systemImage) {
          editorModel.applyBlock(command)
        }
      }
    }
  }

  @ViewBuilder
  private var historyCommands: some View {
    Button("Undo", systemImage: "arrow.uturn.backward", action: editorModel.undo)
      .disabled(!editorModel.canUndo)
    Button("Redo", systemImage: "arrow.uturn.forward", action: editorModel.redo)
      .disabled(!editorModel.canRedo)
  }

  private func inlineButton(
    _ command: SemanticMessageInlineCommand
  ) -> some View {
    Button(command.title, systemImage: command.systemImage) {
      editorModel.toggleInline(command)
    }
    .labelStyle(.iconOnly)
    .frame(minWidth: 44, minHeight: 44)
  }
}

private struct MailComposerKeyboardCommands: View {
  @Bindable var editorModel: SemanticMessageEditorModel
  let requestLink: () -> Void

  var body: some View {
    Group {
      Button("Bold", action: toggleBold)
        .keyboardShortcut("b", modifiers: .command)
      Button("Italic", action: toggleItalic)
        .keyboardShortcut("i", modifiers: .command)
      Button("Underline", action: toggleUnderline)
        .keyboardShortcut("u", modifiers: .command)
      Button("Add Link", action: requestLink)
        .keyboardShortcut("k", modifiers: .command)
    }
    .frame(width: 0, height: 0)
    .opacity(0)
    .accessibilityHidden(true)
  }

  private func toggleBold() {
    editorModel.toggleInline(.bold)
  }

  private func toggleItalic() {
    editorModel.toggleInline(.italic)
  }

  private func toggleUnderline() {
    editorModel.toggleInline(.underline)
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
