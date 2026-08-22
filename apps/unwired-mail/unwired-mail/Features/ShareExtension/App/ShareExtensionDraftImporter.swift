import Foundation

/// Saves imported extension payloads into the normal encrypted Draft repository.
protocol ShareExtensionDraftRepository: Sendable {
  func save(
    _ draft: MailShellCompositionDraft,
    productAccountId: String,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot?
  ) async throws
}

extension MailCompositionDraftRepository: ShareExtensionDraftRepository {}

/// Identifies one pending payload successfully admitted to the normal Draft store.
struct ShareExtensionImportedDraft: Equatable, Sendable {
  let draftId: UUID
  let profileId: MailProfileId
}

/// Converts and atomically advances encrypted share intake into ordinary Draft persistence.
actor ShareExtensionDraftImporter {
  private let repository: any ShareExtensionDraftRepository
  private let store: any ShareExtensionStoring

  /// Creates an importer with explicit persistence boundaries.
  init(
    store: any ShareExtensionStoring,
    repository: any ShareExtensionDraftRepository
  ) {
    self.repository = repository
    self.store = store
  }

  /// Imports current-account payloads and preserves every payload that cannot be admitted.
  func importPendingDrafts(
    session: ProductAccountSessionSnapshot
  ) async throws -> [ShareExtensionImportedDraft] {
    let pendingDrafts = try await store.loadPendingDrafts()
    var imported: [ShareExtensionImportedDraft] = []
    for payload in pendingDrafts where payload.productAccountId == session.productAccountId {
      try Task.checkCancellation()
      let profileId = MailProfileId(rawValue: payload.profileId)
      try await repository.save(
        try payload.mailCompositionDraft,
        productAccountId: session.productAccountId,
        profileId: profileId,
        session: session
      )
      try await store.removePendingDraft(payload.id)
      imported.append(ShareExtensionImportedDraft(draftId: payload.id, profileId: profileId))
    }
    return imported
  }
}

extension ShareExtensionDraftPayload {
  fileprivate var mailCompositionDraft: MailShellCompositionDraft {
    get throws {
      guard let separator = connectionId.firstIndex(of: ":") else {
        throw ShareExtensionStoreError.invalidStoredData
      }
      let providerId = String(connectionId[..<separator])
      let providerMailboxValue = String(connectionId[connectionId.index(after: separator)...])
      guard !providerId.isEmpty, !providerMailboxValue.isEmpty else {
        throw ShareExtensionStoreError.invalidStoredData
      }
      let document = SemanticMessageDocument(
        blocks: blocks.map { block in
          SemanticMessageDocument.Block(
            runs: block.runs.map { run in
              SemanticMessageDocument.Run(
                run.text,
                link: run.link,
                inlineAssetId: run.inlineAssetId
              )
            }
          )
        }
      )
      let draftAssets = assets.map { asset in
        MailDraftAsset(
          data: asset.data,
          filename: asset.filename,
          mediaType: asset.mediaType,
          disposition: asset.disposition == .inline ? .inline : .attachment,
          id: asset.id
        )
      }
      return MailShellCompositionDraft(
        body: document.plainText,
        connectionId: MailboxConnectionId(
          providerMailboxIdentity: StableProviderMailboxIdentity(
            providerId: MailProviderId(rawValue: providerId),
            value: providerMailboxValue
          )
        ),
        recipient: "",
        replyToMessage: nil,
        sourceMessage: nil,
        subject: "",
        id: id,
        kind: .newMessage,
        sendingIdentityId: SendingIdentityId(rawValue: sendingIdentityId),
        updatedAtMilliseconds: createdAtMilliseconds,
        document: document,
        assets: draftAssets
      )
    }
  }
}
