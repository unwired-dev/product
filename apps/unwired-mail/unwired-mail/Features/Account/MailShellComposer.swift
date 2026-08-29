import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// swiftlint:disable file_length

private enum MailComposerFocus: Hashable {
  case bcc
  case cc  // swiftlint:disable:this identifier_name
  case to  // swiftlint:disable:this identifier_name
}

private struct MailRecipientSuggestionRequest: Equatable {
  let field: MailComposerFocus?
  let query: String
}

/// The mail-shell navigation actions available to an embedded composer.
struct MailShellComposerNavigation {
  let drafts: [MailShellCompositionDraft]
  let isExpanded: Bool
  let showsExpansionControl: Bool
  let dismiss: () -> Void
  let newMessage: () -> Void
  let openDraft: (MailShellCompositionDraft) -> Void
  let toggleExpansion: () -> Void
}

// swiftlint:disable:next type_body_length
struct MailShellComposer: View {
  let connections: [MailboxConnection]
  let draftDidChange: (MailShellCompositionDraft) -> Void
  let isSending: Bool
  let mailAssistanceViewModel: MailAssistanceViewModel?
  let navigation: MailShellComposerNavigation?
  let preferences: ComposePreferences
  let profileName: String
  let readingPreferences: ReadingPreferences
  let recipientMessages: [MailboxMessageMetadata]
  let responseAssistanceContext: ResponseAssistanceContext?
  let sendingIdentities: [SendingIdentity]
  let signatures: SignaturePreferences
  let templates: TemplatePreferences
  let scheduledSendDueAt: Date?
  let sendNow: MailComposerViewModel.SendDraft?

  @FocusState private var focusedField: MailComposerFocus?
  @State private var isBodyFocused = false
  @State private var isBodyFocusPending = false
  @State private var isSubjectFocused = false
  @State private var subjectFocusRequest = 0
  @State private var bodyFocusRequest = 0
  @State private var bodyFocusHandoff = 0
  @State private var presentsSubjectField = true
  @State private var assetErrorMessage: String?
  @State private var translationErrorMessage: String?
  @State private var composeAssistancePresentation: ComposeAssistancePresentation?
  @State private var translationPresentation: MailTranslationPresentation?
  @State private var responseAssistancePresentation: ResponseAssistancePresentation?
  @State private var linkDestination = "https://"
  @State private var pendingFileImportDraftId: UUID?
  @State private var recipientEditor: MailRecipientEditor
  @State private var sendLaterRequest: SendLaterRequest?
  @State private var selectedPhoto: PhotosPickerItem?
  @State private var selectedSuggestionId: String?
  @State private var suggestions: [MailRecipientSuggestion] = []
  @State private var showsDiscardConfirmation = false
  @State private var showsExpandedRecipients = false
  @State private var showsMissingSubjectConfirmation = false
  @State private var showsLinkEditor = false
  @State private var showsFileImporter = false
  @State private var showsQuotedText = false
  @State private var suggestionService: MailRecipientSuggestionService
  @State private var viewModel: MailComposerViewModel

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
    responseAssistanceContext: ResponseAssistanceContext? = nil,
    sendingIdentities: [SendingIdentity] = [],
    navigation: MailShellComposerNavigation? = nil,
    suggestionService: MailRecipientSuggestionService = MailRecipientSuggestionService(),
    draftDidChange: @escaping (MailShellCompositionDraft) -> Void = { _ in },
    scheduledSendDueAt: Date? = nil,
    sendNow: MailComposerViewModel.SendDraft? = nil
  ) {
    self.connections = connections
    self.draftDidChange = draftDidChange
    self.isSending = isSending
    self.mailAssistanceViewModel = mailAssistanceViewModel
    self.navigation = navigation
    self.preferences = preferences
    self.profileName = profileName
    self.readingPreferences = readingPreferences
    self.recipientMessages = recipientMessages
    self.responseAssistanceContext = responseAssistanceContext
    self.sendingIdentities = sendingIdentities
    self.signatures = signatures
    self.templates = templates
    self.scheduledSendDueAt = scheduledSendDueAt
    self.sendNow = sendNow
    _recipientEditor = State(
      initialValue: MailRecipientEditor(
        to: viewModel.draft.recipient,
        cc: viewModel.draft.ccRecipients,
        bcc: viewModel.draft.bccRecipients
      )
    )
    _suggestionService = State(initialValue: suggestionService)
    _viewModel = State(initialValue: viewModel)
  }

  @ViewBuilder
  var body: some View {
    #if os(macOS)
      composer
        .frame(minWidth: 560, minHeight: 520)
    #else
      composer
    #endif
  }

  private var composer: some View {
    composerContent
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
        Button("Add Subject", role: .cancel, action: focusSubject)
      } message: {
        missingSubjectMessage
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
        sendLaterSheet
      }
  }

  private var composerHeader: some View {
    @Bindable var viewModel = viewModel
    return MailComposerHeader(
      title: viewModel.draft.title,
      close: closeComposer,
      actionsAreDisabled: viewModel.saveState == .saving || viewModel.isSwitchingDraft,
      expansion: headerExpansion,
      canAutomaticallySend: canScheduleSend,
      canSendLater: viewModel.canCreateSendReminder,
      isSendEnabled: isSendEnabled,
      sendTitle: scheduledSendDueAt == nil ? "Send" : "Save Changes",
      send: sendDraft,
      sendLater: openSendLater,
      sendNow: scheduledSendDueAt != nil && sendNow != nil ? sendScheduledNow : nil,
      selectedPhoto: $selectedPhoto,
      switching: navigation.map {
        MailComposerHeader.Switching(
          canSwitch: !viewModel.isSwitchingDraft,
          drafts: $0.drafts.filter { $0.id != viewModel.draft.id },
          newMessage: $0.newMessage,
          openDraft: $0.openDraft
        )
      },
      discard: requestDiscard
    )
  }

  private var composerContent: some View {
    NavigationStack {
      composerLifecycleEditor
    }
  }

  private var composerEditor: some View {
    @Bindable var viewModel = viewModel
    return VStack(spacing: 0) {
      composerHeader
      Divider()
      ScrollView {
        VStack(spacing: 0) {
          MailComposerIdentityRow(
            connections: connections,
            identities: sendingIdentities,
            profileName: profileName,
            selectedIdentityId: $viewModel.draft.sendingIdentityId
          )
          Divider()
          recipientFields
          Divider()
          MailComposerSubjectRow(
            subject: $viewModel.draft.subject,
            isFocused: $isSubjectFocused,
            focusRequest: subjectFocusRequest,
            presentsField: presentsSubjectField,
            focusBody: focusBody,
            focusSubject: focusSubject
          )
          Divider()
          MailComposerActionBar(
            editorModel: editorModel,
            hasQuotedText: viewModel.draft.quotedText?.isEmpty == false,
            requestFile: {
              pendingFileImportDraftId = viewModel.draft.id
              showsFileImporter = true
            },
            requestLink: requestLink,
            showsFormattingToolbar: preferences.showsFormattingToolbar,
            showsExpandedRecipients: $showsExpandedRecipients,
            showsQuotedText: $showsQuotedText,
            signatures: signatures,
            selectedSignatureId: selectedSignatureId,
            templates: templates,
            applyTemplate: applyTemplate,
            requestAssistance: mailAssistanceViewModel == nil ? nil : requestComposeAssistance,
            requestResponseAssistance: responseAssistanceAction,
            requestTranslation: mailAssistanceViewModel == nil ? nil : requestTranslation
          )
          Divider()
          MailComposerBodyField(
            editorModel: editorModel,
            composeAssistanceContext: composeAssistanceContext,
            isFocused: $isBodyFocused,
            focusRequest: bodyFocusRequest,
            focusDidBegin: bodyFocusDidBegin
          )
          .simultaneousGesture(
            TapGesture().onEnded {
              requestBodyFocus()
            }
          )
          .dropDestination(for: Data.self) { items, _ in
            addDroppedImages(items)
            return !items.isEmpty
          }
          .dropDestination(for: URL.self) { urls, _ in
            importFiles(.success(urls), draftId: viewModel.draft.id)
            return !urls.isEmpty
          }
          Divider()
          composerSupplementalDetails
        }
      }
      .scrollDismissesKeyboard(.interactively)
      .accessibilityIdentifier("mail-compose-document-scroll")
    }
  }

  private var composerPresentationEditor: some View {
    @Bindable var viewModel = viewModel
    return
      composerEditor
      .fileImporter(
        isPresented: $showsFileImporter,
        allowedContentTypes: [.data],
        allowsMultipleSelection: true,
        onCompletion: { result in
          guard let pendingFileImportDraftId else { return }
          importFiles(result, draftId: pendingFileImportDraftId)
        }
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
      .sheet(item: $responseAssistancePresentation) { presentation in
        if let mailAssistanceViewModel {
          ResponseAssistanceView(
            presentation: presentation,
            assistanceViewModel: mailAssistanceViewModel,
            draft: currentResponseDraft,
            applyDocument: applyResponseDocument
          )
        }
      }
      .sheet(item: $translationPresentation) { presentation in
        if let mailAssistanceViewModel {
          MailTranslationView(
            presentation: presentation,
            assistanceViewModel: mailAssistanceViewModel,
            currentInputVersion: {
              guard let target = presentation.draftTarget else {
                return MailAssistanceInputVersion()
              }
              return ComposeAssistanceRequestBuilder.inputVersion(
                document: editorModel.document,
                target: target,
                subject: viewModel.draft.subject,
                recipientDisplayNames: recipientDisplayNames
              )
            },
            applyDraftTranslation: { translatedText in
              guard let target = presentation.draftTarget else { return false }
              return editorModel.applyAssistanceDocument(
                SemanticMessageDocument(plainText: translatedText),
                application: .replaceTarget,
                target: target
              )
            }
          )
        }
      }
  }

  private var composerInputLifecycleEditor: some View {
    @Bindable var viewModel = viewModel
    return
      composerPresentationEditor
      .onChange(of: selectedPhoto) { _, item in
        guard let item else { return }
        let draftId = viewModel.draft.id
        Task { await importPhoto(item, draftId: draftId) }
      }
      .onChange(of: focusedField) { previousField, focusedField in
        if focusedField != nil {
          bodyFocusHandoff &+= 1
          isBodyFocusPending = false
          presentsSubjectField = true
          isBodyFocused = false
          isSubjectFocused = false
        }
        guard let recipientField = recipientField(for: previousField) else { return }
        recipientEditor.commitPendingText(in: recipientField)
      }
      .onChange(of: isSubjectFocused) { _, isSubjectFocused in
        if isBodyFocusPending, isSubjectFocused {
          self.isSubjectFocused = false
          isBodyFocused = true
          bodyFocusRequest &+= 1
          return
        }
        if isSubjectFocused {
          bodyFocusHandoff &+= 1
          isBodyFocusPending = false
          focusedField = nil
          isBodyFocused = false
        }
      }
      .onChange(of: recipientEditor.headers) { _, headers in
        synchronizeRecipientHeaders(headers)
      }
  }

  private var composerLifecycleEditor: some View {
    @Bindable var viewModel = viewModel
    return
      composerInputLifecycleEditor
      .task {
        viewModel.draftChanged()
        await Task.yield()
        guard focusedField == nil, isBodyFocused == false else { return }
        if viewModel.draft.recipient.isEmpty {
          focusedField = .to
        } else {
          isBodyFocused = true
        }
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
      .onChange(of: viewModel.draft.id) { _, _ in
        resetDraftPresentation()
      }
      .onChange(of: editorModel.document) { _, document in
        guard viewModel.draft.document != document else { return }
        viewModel.editorDocumentChanged()
      }
      .interactiveDismissDisabled(
        viewModel.hasUnsavedChanges || viewModel.saveState.blocksDismissal
      )
  }

  private var sendLaterSheet: some View {
    SendLaterSheet(
      existingReminder: viewModel.draft.sendReminder,
      existingAutomaticDueAt: scheduledSendDueAt,
      canAutomaticallySend: canScheduleSend,
      scheduleAutomatically: { dueAt, timeZone in
        let scheduled = await viewModel.scheduleSend(
          at: dueAt,
          timeZoneIdentifier: timeZone
        )
        if scheduled { dismissComposer() }
        return scheduled
      },
      schedule: { dueAt, timeZone in
        await viewModel.remind(at: dueAt, timeZoneIdentifier: timeZone)
      }
    )
  }

  private var missingSubjectMessage: Text {
    Text("The message has no subject. You can add one or send it as written.")
  }

  private var editorModel: SemanticMessageEditorModel {
    viewModel.editorModel
  }

  private var composerSupplementalDetails: some View {
    @Bindable var viewModel = viewModel
    return VStack(spacing: 12) {
      if let signature = viewModel.draft.signature {
        MailComposerSignatureSummary(signature: signature)
      }
      if let reminder = viewModel.draft.sendReminder {
        MailComposerReminderSummary(
          notificationState: viewModel.reminderState,
          reminder: reminder
        )
      }
      if let scheduledSendDueAt {
        LabeledContent(
          "Scheduled", value: scheduledSendDueAt.formatted(date: .abbreviated, time: .shortened)
        )
        .foregroundStyle(.secondary)
      }
      MailComposerAssetList(
        assets: viewModel.draft.assets,
        remove: removeAsset,
        toggleDisposition: toggleAssetDisposition
      )
      if let assetStatusMessage {
        MailComposerAssetStatus(message: assetStatusMessage)
      }
      if let translationErrorMessage {
        MailComposerAssetStatus(message: translationErrorMessage)
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

  private var headerExpansion: MailComposerHeader.Expansion? {
    guard let navigation, navigation.showsExpansionControl else { return nil }
    return MailComposerHeader.Expansion(
      isExpanded: navigation.isExpanded,
      toggle: navigation.toggleExpansion
    )
  }

  private func focusBody() {
    bodyFocusHandoff &+= 1
    let handoff = bodyFocusHandoff
    isBodyFocusPending = true
    focusedField = nil
    isSubjectFocused = false
    Task { @MainActor in
      await Task.yield()
      guard handoff == bodyFocusHandoff, isBodyFocusPending, focusedField == nil else { return }
      isBodyFocused = true
      bodyFocusRequest &+= 1
    }
  }

  private func bodyFocusDidBegin() {
    guard isBodyFocusPending else { return }
    let handoff = bodyFocusHandoff
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(100))
      guard
        handoff == bodyFocusHandoff,
        isBodyFocusPending,
        focusedField == nil,
        isBodyFocused
      else { return }
      isBodyFocusPending = false
    }
  }

  private func focusSubject() {
    bodyFocusHandoff &+= 1
    let handoff = bodyFocusHandoff
    isBodyFocusPending = false
    isBodyFocused = false
    presentsSubjectField = true
    Task { @MainActor in
      await Task.yield()
      guard handoff == bodyFocusHandoff, isBodyFocused == false else { return }
      subjectFocusRequest &+= 1
      isSubjectFocused = true
    }
  }

  private func requestBodyFocus() {
    bodyFocusHandoff &+= 1
    isBodyFocusPending = false
    presentsSubjectField = true
    focusedField = nil
    isSubjectFocused = false
    isBodyFocused = true
    bodyFocusRequest &+= 1
  }

  private func resetDraftPresentation() {
    bodyFocusHandoff &+= 1
    isBodyFocusPending = false
    presentsSubjectField = true
    isSubjectFocused = false
    sendLaterRequest = nil
    pendingFileImportDraftId = nil
    selectedPhoto = nil
    showsDiscardConfirmation = false
    showsFileImporter = false
    showsLinkEditor = false
    showsMissingSubjectConfirmation = false
    recipientEditor = MailRecipientEditor(
      to: viewModel.draft.recipient,
      cc: viewModel.draft.ccRecipients,
      bcc: viewModel.draft.bccRecipients
    )
    assetErrorMessage = nil
    translationErrorMessage = nil
    composeAssistancePresentation = nil
    translationPresentation = nil
    responseAssistancePresentation = nil
    selectedSuggestionId = nil
    suggestions = []
    showsExpandedRecipients = false
    showsQuotedText = false
    focusedField = viewModel.draft.recipient.isEmpty ? .to : nil
    isBodyFocused = !viewModel.draft.recipient.isEmpty
    if isBodyFocused { bodyFocusRequest &+= 1 }
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
        tokens: recipientEditor.tokens(in: .to),
        pendingText: pendingRecipientBinding(for: .to),
        issue: recipientEditor.issue(in: .to),
        focus: .to,
        focusedField: $focusedField,
        remove: { recipientEditor.remove($0, from: .to) },
        submit: { submitRecipientField(.to) },
        handleKeyPress: { handleRecipientKeyPress($0, in: .to) }
      )
      if focusedField == .to {
        MailRecipientSuggestionList(
          suggestions: suggestions,
          selectedSuggestionId: selectedSuggestionId,
          select: applySuggestion
        )
      }
      if showsOptionalRecipientFields {
        Divider()
        MailComposerRecipientField(
          label: "Cc",
          tokens: recipientEditor.tokens(in: .cc),
          pendingText: pendingRecipientBinding(for: .cc),
          issue: recipientEditor.issue(in: .cc),
          focus: .cc,
          focusedField: $focusedField,
          remove: { recipientEditor.remove($0, from: .cc) },
          submit: { submitRecipientField(.cc) },
          handleKeyPress: { handleRecipientKeyPress($0, in: .cc) }
        )
        if focusedField == .cc {
          MailRecipientSuggestionList(
            suggestions: suggestions,
            selectedSuggestionId: selectedSuggestionId,
            select: applySuggestion
          )
        }
        Divider()
        MailComposerRecipientField(
          label: "Bcc",
          tokens: recipientEditor.tokens(in: .bcc),
          pendingText: pendingRecipientBinding(for: .bcc),
          issue: recipientEditor.issue(in: .bcc),
          focus: .bcc,
          focusedField: $focusedField,
          remove: { recipientEditor.remove($0, from: .bcc) },
          submit: { submitRecipientField(.bcc) },
          handleKeyPress: { handleRecipientKeyPress($0, in: .bcc) }
        )
        if focusedField == .bcc {
          MailRecipientSuggestionList(
            suggestions: suggestions,
            selectedSuggestionId: selectedSuggestionId,
            select: applySuggestion
          )
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
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
    if let noticeMessage = viewModel.noticeMessage {
      Label(noticeMessage, systemImage: "exclamationmark.triangle")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    } else {
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
    ScheduledSendReleasePolicy.allowsAutomaticScheduling(
      existingSchedule: scheduledSendDueAt != nil
    ) && isSendEnabled
      && selectedConnection?.providerId.supportsProductOwnedScheduledSend == true
      && (viewModel.draft.kind != .editing || scheduledSendDueAt != nil)
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
    guard let field = recipientField(for: focusedField) else { return "" }
    return recipientEditor.pendingText(in: field)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var showsOptionalRecipientFields: Bool {
    showsExpandedRecipients || recipientEditor.hasPopulatedOptionalRecipients
  }

  private func pendingRecipientBinding(for field: MailRecipientEditor.Field) -> Binding<String> {
    Binding(
      get: { recipientEditor.pendingText(in: field) },
      set: { recipientEditor.updatePendingText($0, in: field) }
    )
  }

  private func recipientField(for focus: MailComposerFocus?) -> MailRecipientEditor.Field? {
    guard let focus else { return nil }
    return switch focus {
    case .bcc: .bcc
    case .cc: .cc
    case .to: .to
    }
  }

  private func synchronizeRecipientHeaders(_ headers: MailRecipientEditor.Headers) {
    guard
      viewModel.draft.recipient != headers.to
        || viewModel.draft.ccRecipients != headers.cc
        || viewModel.draft.bccRecipients != headers.bcc
    else { return }
    viewModel.draft.recipient = headers.to
    viewModel.draft.ccRecipients = headers.cc
    viewModel.draft.bccRecipients = headers.bcc
  }

  private func submitRecipientField(_ field: MailRecipientEditor.Field) {
    if let suggestion = selectedSuggestion {
      applySuggestion(suggestion)
    } else {
      recipientEditor.commitPendingText(in: field)
    }
  }

  private func handleRecipientKeyPress(
    _ key: KeyEquivalent,
    in field: MailRecipientEditor.Field
  ) -> KeyPress.Result {
    switch key {
    case .upArrow:
      return moveSuggestionSelection(by: -1)
    case .downArrow:
      return moveSuggestionSelection(by: 1)
    case .tab:
      guard let suggestion = selectedSuggestion else {
        recipientEditor.commitPendingText(in: field)
        return .ignored
      }
      applySuggestion(suggestion)
      return .handled
    default:
      return .ignored
    }
  }

  private var selectedSuggestion: MailRecipientSuggestion? {
    guard let selectedSuggestionId else { return nil }
    return suggestions.first(where: { $0.id == selectedSuggestionId })
  }

  private func moveSuggestionSelection(by offset: Int) -> KeyPress.Result {
    guard !suggestions.isEmpty else { return .ignored }
    let nextIndex: Int
    if let selectedSuggestion,
      let currentIndex = suggestions.firstIndex(where: { $0.id == selectedSuggestion.id })
    {
      nextIndex = (currentIndex + offset + suggestions.count) % suggestions.count
    } else {
      nextIndex = offset > 0 ? 0 : suggestions.count - 1
    }
    selectedSuggestionId = suggestions[nextIndex].id
    return .handled
  }

  private func focus(for field: MailRecipientEditor.Field) -> MailComposerFocus {
    switch field {
    case .bcc: .bcc
    case .cc: .cc
    case .to: .to
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
    let request = suggestionRequest
    guard let field = recipientField(for: request.field), !request.query.isEmpty
    else {
      suggestions = []
      selectedSuggestionId = nil
      return
    }
    suggestions = []
    selectedSuggestionId = nil
    do {
      try await Task.sleep(for: .milliseconds(150))
    } catch is CancellationError {
      return
    } catch {
      return
    }
    let loaded = await suggestionService.suggestions(
      matching: request.query,
      messages: recipientMessages
    )
    guard !Task.isCancelled, request == suggestionRequest else { return }
    suggestions = loaded.filter { !recipientEditor.contains(emailAddress: $0.emailAddress) }
    selectedSuggestionId = nil
    if focusedField != focus(for: field) {
      suggestions = []
      selectedSuggestionId = nil
    }
  }

  private func applySuggestion(_ suggestion: MailRecipientSuggestion) {
    guard let field = recipientField(for: focusedField) else { return }
    recipientEditor.accept(suggestion, in: field)
    suggestions = []
    selectedSuggestionId = nil
  }

  private func closeComposer() {
    Task {
      if await viewModel.close() { dismissComposer() }
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
      if await viewModel.discard() { dismissComposer() }
    }
  }

  private func sendDraft() {
    Task {
      switch await viewModel.send() {
      case .needsSubjectConfirmation:
        showsMissingSubjectConfirmation = true
      case .sent:
        dismissComposer()
      case .notSent:
        break
      }
    }
  }

  private func sendWithoutSubject() {
    Task {
      if await viewModel.sendWithoutSubject() == .sent { dismissComposer() }
    }
  }

  private func sendScheduledNow() {
    guard let sendNow else { return }
    Task {
      if await sendNow(viewModel.draft) { dismissComposer() }
    }
  }

  private func dismissComposer() {
    navigation?.dismiss()
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

  private var composeAssistanceContext: SemanticMessageTextView.ComposeAssistanceContext? {
    guard let mailAssistanceViewModel else { return nil }
    return SemanticMessageTextView.ComposeAssistanceContext(
      viewModel: mailAssistanceViewModel,
      currentSubject: { viewModel.draft.subject },
      recipientDisplayNames: { recipientDisplayNames },
      applySubject: { subject in viewModel.draft.subject = subject }
    )
  }

  private func requestTranslation() {
    guard let mailAssistanceViewModel else { return }
    let target = editorModel.composeAssistanceTarget()
    do {
      let presentation = try MailTranslationRequestBuilder.draftSelection(
        target: target,
        inputVersion: ComposeAssistanceRequestBuilder.inputVersion(
          document: editorModel.document,
          target: target,
          subject: viewModel.draft.subject,
          recipientDisplayNames: recipientDisplayNames
        ),
        profileId: mailAssistanceViewModel.activeProfileId
      )
      mailAssistanceViewModel.discardPreview()
      translationErrorMessage = nil
      translationPresentation = presentation
    } catch {
      translationErrorMessage =
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
  }

  private var responseAssistanceAction: (() -> Void)? {
    guard mailAssistanceViewModel != nil,
      responseAssistanceContext != nil,
      viewModel.draft.kind == .reply || viewModel.draft.kind == .replyAll
    else { return nil }
    return requestResponseAssistance
  }

  private func requestResponseAssistance() {
    guard let mailAssistanceViewModel, let responseAssistanceContext else { return }
    mailAssistanceViewModel.discardPreview()
    responseAssistancePresentation = ResponseAssistancePresentation(
      context: responseAssistanceContext,
      localeIdentifier: Locale.current.identifier,
      profileId: mailAssistanceViewModel.activeProfileId
    )
  }

  private func currentResponseDraft() -> MailShellCompositionDraft {
    var draft = viewModel.draft
    draft.document = editorModel.document
    return draft
  }

  private func applyResponseDocument(_ document: SemanticMessageDocument) -> Bool {
    let sourceDocument = editorModel.document
    let target = ComposeAssistanceTarget(
      insertionOffset: sourceDocument.attributedText.characters.count,
      range: nil,
      scope: .authoredBody,
      sourceDocument: sourceDocument,
      targetDocument: sourceDocument
    )
    let didApply = editorModel.applyAssistanceDocument(
      document,
      application: .replaceTarget,
      target: target
    )
    if didApply {
      responseAssistancePresentation = nil
      mailAssistanceViewModel?.discardPreview()
    }
    return didApply
  }

  private var recipientDisplayNames: [String] {
    [recipientEditor.headers.to, recipientEditor.headers.cc]
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

  static func fileImportTargetsActiveDraft(_ draftId: UUID, activeDraftId: UUID) -> Bool {
    draftId == activeDraftId
  }

  private func importFiles(_ result: Result<[URL], Error>, draftId: UUID) {
    guard Self.fileImportTargetsActiveDraft(draftId, activeDraftId: viewModel.draft.id) else {
      return
    }
    if pendingFileImportDraftId == draftId { pendingFileImportDraftId = nil }
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

  private func importPhoto(_ item: PhotosPickerItem, draftId: UUID) async {
    do {
      guard let data = try await item.loadTransferable(type: Data.self) else {
        guard draftId == viewModel.draft.id else { return }
        assetErrorMessage = "Can't attach the selected photo. Choose another photo."
        return
      }
      guard draftId == viewModel.draft.id else { return }
      viewModel.draft.addAsset(
        MailDraftAsset(
          data: data,
          filename: "Photo.heic",
          mediaType: item.supportedContentTypes.first?.preferredMIMEType ?? "image/heic"
        )
      )
      assetErrorMessage = nil
    } catch {
      guard draftId == viewModel.draft.id else { return }
      assetErrorMessage = "Can't attach the selected photo. Choose another photo."
    }
    if draftId == viewModel.draft.id { selectedPhoto = nil }
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

private struct MailComposerHeader: View {
  struct Expansion {
    let isExpanded: Bool
    let toggle: () -> Void
  }

  struct Switching {
    let canSwitch: Bool
    let drafts: [MailShellCompositionDraft]
    let newMessage: () -> Void
    let openDraft: (MailShellCompositionDraft) -> Void
  }

  let title: String
  let close: () -> Void
  let actionsAreDisabled: Bool
  let expansion: Expansion?
  let canAutomaticallySend: Bool
  let canSendLater: Bool
  let isSendEnabled: Bool
  let sendTitle: String
  let send: () -> Void
  let sendLater: () -> Void
  let sendNow: (() -> Void)?
  @Binding var selectedPhoto: PhotosPickerItem?
  let switching: Switching?
  let discard: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Button("Close Composer", systemImage: "xmark", action: close)
        .labelStyle(.iconOnly)
        .frame(minWidth: 44, minHeight: 44)
        .disabled(actionsAreDisabled)
        .accessibilityIdentifier("mail-compose-close")
      Text(title)
        .font(.headline)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
      if let expansion {
        Button(
          expansion.isExpanded ? "Collapse Composer" : "Expand Composer",
          systemImage: expansion.isExpanded
            ? "arrow.down.right.and.arrow.up.left"
            : "arrow.up.left.and.arrow.down.right",
          action: expansion.toggle
        )
        .labelStyle(.iconOnly)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityIdentifier("mail-compose-expansion")
      }
      Menu("More", systemImage: "ellipsis") {
        if let switching {
          Button("New Message", systemImage: "square.and.pencil", action: switching.newMessage)
            .disabled(!switching.canSwitch)
          if !switching.drafts.isEmpty {
            Menu("Open Draft", systemImage: "doc.text") {
              ForEach(switching.drafts) { draft in
                Button(draft.menuTitle) {
                  switching.openDraft(draft)
                }
                .disabled(!switching.canSwitch)
              }
            }
          }
          Divider()
        }
        if let sendNow {
          Button("Send Now", systemImage: "paperplane.fill", action: sendNow)
            .disabled(!isSendEnabled)
        }
        Button("Send Later", systemImage: "clock", action: sendLater)
          .disabled(!canSendLater)
          .keyboardShortcut("l", modifiers: [.command, .shift])
        PhotosPicker(selection: $selectedPhoto, matching: .images) {
          Label("Attach Photo", systemImage: "photo")
        }
        Divider()
        Button("Discard Draft", systemImage: "trash", role: .destructive, action: discard)
      }
      .labelStyle(.iconOnly)
      .frame(minWidth: 44, minHeight: 44)
      .disabled(actionsAreDisabled)
      .accessibilityIdentifier("mail-compose-more")
      MailComposerSendButton(
        title: sendTitle,
        canAutomaticallySend: canAutomaticallySend,
        canSendLater: canSendLater,
        isSendEnabled: isSendEnabled,
        send: send,
        sendLater: sendLater
      )
      .buttonStyle(.borderedProminent)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
  }
}

private struct MailComposerBodyField: View {
  @Bindable var editorModel: SemanticMessageEditorModel
  let composeAssistanceContext: SemanticMessageTextView.ComposeAssistanceContext?
  @Binding var isFocused: Bool
  let focusRequest: Int
  let focusDidBegin: () -> Void

  var body: some View {
    SemanticMessageTextView(
      editorModel: editorModel,
      composeAssistanceContext: composeAssistanceContext,
      isFocused: $isFocused,
      focusRequest: focusRequest,
      focusDidBegin: focusDidBegin,
      minimumHeight: 160
    )
    .frame(maxWidth: .infinity, alignment: .topLeading)
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
  let requestResponseAssistance: (() -> Void)?
  let requestTranslation: (() -> Void)?

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
      if let requestResponseAssistance {
        Button(
          "Response Assistance",
          systemImage: "text.bubble",
          action: requestResponseAssistance
        )
        .labelStyle(.iconOnly)
      }
      if let requestTranslation {
        Button("Translate Selection", systemImage: "character.bubble", action: requestTranslation)
          .labelStyle(.iconOnly)
      }
      MailComposerKeyboardCommands(editorModel: editorModel, requestLink: requestLink)
      Spacer()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
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
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }
}

private struct MailComposerSubjectRow: View {
  @Binding var subject: String
  @Binding var isFocused: Bool
  let focusRequest: Int
  let presentsField: Bool
  let focusBody: () -> Void
  let focusSubject: () -> Void

  var body: some View {
    if presentsField {
      MailComposerSubjectField(
        subject: $subject,
        isFocused: $isFocused,
        focusRequest: focusRequest,
        focusBody: focusBody
      )
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
    } else {
      Button(action: focusSubject) {
        Text(subject.isEmpty ? "Subject" : subject)
          .foregroundStyle(subject.isEmpty ? Color.secondary : Color.primary)
          .padding(.horizontal, 16)
          .padding(.vertical, 12)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("mail-compose-subject")
    }
  }
}

private struct MailComposerSubjectField: UIViewRepresentable {
  private final class SubjectTextField: UITextField {
    var submit: (() -> Void)?

    override func insertText(_ text: String) {
      guard text != "\n", text != "\r" else {
        submit?()
        return
      }
      super.insertText(text)
    }
  }

  @Binding var subject: String
  @Binding var isFocused: Bool
  let focusRequest: Int
  let focusBody: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  func makeUIView(context: Context) -> UITextField {
    let textField = SubjectTextField()
    textField.adjustsFontForContentSizeCategory = true
    textField.font = .preferredFont(forTextStyle: .body)
    textField.placeholder = "Subject"
    textField.returnKeyType = .next
    textField.accessibilityIdentifier = "mail-compose-subject"
    textField.delegate = context.coordinator
    textField.addTarget(
      context.coordinator,
      action: #selector(Coordinator.subjectDidChange),
      for: .editingChanged
    )
    textField.submit = { [weak coordinator = context.coordinator, weak textField] in
      guard let textField else { return }
      coordinator?.submit(textField)
    }
    return textField
  }

  func updateUIView(_ textField: UITextField, context: Context) {
    context.coordinator.parent = self
    if textField.text != subject { textField.text = subject }
    if isFocused {
      context.coordinator.focus(textField, for: focusRequest)
    } else if textField.isFirstResponder {
      textField.resignFirstResponder()
    }
  }

  @MainActor
  final class Coordinator: NSObject, UITextFieldDelegate {
    var parent: MailComposerSubjectField
    private var activeFocusRequest: Int?
    private var focusesBodyAfterEditingEnds = false

    init(parent: MailComposerSubjectField) {
      self.parent = parent
    }

    @objc func subjectDidChange(_ textField: UITextField) {
      parent.subject = textField.text ?? ""
    }

    func focus(_ textField: UITextField, for request: Int) {
      guard activeFocusRequest != request else { return }
      activeFocusRequest = request
      if textField.isFirstResponder == false { textField.becomeFirstResponder() }
    }

    func textFieldDidBeginEditing(_: UITextField) {
      activeFocusRequest = parent.focusRequest
      parent.isFocused = true
    }

    func textFieldDidEndEditing(_: UITextField) {
      parent.isFocused = false
      guard focusesBodyAfterEditingEnds else { return }
      focusesBodyAfterEditingEnds = false
      parent.focusBody()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
      submit(textField)
      return false
    }

    func submit(_ textField: UITextField) {
      guard textField.isFirstResponder else { return }
      focusesBodyAfterEditingEnds = true
      parent.isFocused = false
      Task { @MainActor [self, textField] in
        await Task.yield()
        textField.resignFirstResponder()
        guard focusesBodyAfterEditingEnds else { return }
        focusesBodyAfterEditingEnds = false
        parent.focusBody()
      }
    }
  }
}

private struct MailComposerRecipientField: View {
  let label: String
  let tokens: [MailRecipientEditor.Token]
  @Binding var pendingText: String
  let issue: MailRecipientEditor.Issue?
  let focus: MailComposerFocus
  let focusedField: FocusState<MailComposerFocus?>.Binding
  let remove: (MailRecipientEditor.Token) -> Void
  let submit: () -> Void
  let handleKeyPress: (KeyEquivalent) -> KeyPress.Result

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .center, spacing: 8) {
        Text(label)
          .foregroundStyle(.secondary)
          .frame(minWidth: 32, alignment: .leading)
        ScrollView(.horizontal) {
          HStack(spacing: 4) {
            ForEach(tokens) { token in
              Button(
                action: { remove(token) },
                label: {
                  HStack(spacing: 4) {
                    Text(token.title)
                      .lineLimit(1)
                    Image(systemName: "xmark")
                      .accessibilityHidden(true)
                  }
                }
              )
              .buttonStyle(.bordered)
              .accessibilityLabel("Remove \(token.title)")
            }
            TextField(label, text: $pendingText)
              .frame(minWidth: 160)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .focused(focusedField, equals: focus)
              .onSubmit(submit)
              .onKeyPress(keys: [.upArrow, .downArrow, .tab]) {
                handleKeyPress($0.key)
              }
              .accessibilityIdentifier("mail-compose-\(label.lowercased())")
          }
        }
        .scrollIndicators(.hidden)
      }
      if let issue {
        Label(issue.message, systemImage: "exclamationmark.circle")
          .font(.footnote)
          .foregroundStyle(.red)
          .padding(.leading, 40)
          .accessibilityIdentifier("mail-compose-\(label.lowercased())-error")
      }
    }
  }
}

private struct MailRecipientSuggestionList: View {
  let suggestions: [MailRecipientSuggestion]
  let selectedSuggestionId: String?
  let select: (MailRecipientSuggestion) -> Void

  var body: some View {
    if !suggestions.isEmpty {
      Divider()
      VStack(spacing: 0) {
        ForEach(suggestions) { suggestion in
          let isSelected = suggestion.id == selectedSuggestionId
          Button(
            action: { select(suggestion) },
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
                Image(systemName: isSelected ? "checkmark.circle.fill" : "plus.circle")
                  .accessibilityHidden(true)
              }
              .contentShape(.rect)
              .padding(.vertical, 8)
              .padding(.horizontal, 4)
              .background(
                isSelected ? Color.accentColor.opacity(0.12) : .clear,
                in: .rect(cornerRadius: 8)
              )
            }
          )
          .buttonStyle(.plain)
          .accessibilityLabel("Add \(suggestion.headerValue)")
        }
      }
    }
  }
}
