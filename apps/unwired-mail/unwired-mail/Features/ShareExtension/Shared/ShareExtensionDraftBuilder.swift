import Foundation

/// One supported value loaded from the host application's share request.
enum ShareExtensionInput: Equatable, Sendable {
  case file(data: Data, filename: String, mediaType: String)
  case image(data: Data, filename: String, mediaType: String)
  case link(URL)
  case text(String)
}

/// Builds the provider-independent semantic payload imported by the containing app.
struct ShareExtensionDraftBuilder {
  /// Creates one Profile- and Sending Identity-bound pending Draft.
  func makeDraft(
    id: UUID,
    inputs: [ShareExtensionInput],
    catalog: ShareExtensionCatalog,
    profile: ShareExtensionProfile,
    identity: ShareExtensionSendingIdentity,
    now: Date = .now
  ) throws -> ShareExtensionDraftPayload {
    let content = makeContent(from: inputs)
    let draft = ShareExtensionDraftPayload(
      assets: content.assets,
      blocks: content.blocks.isEmpty
        ? [ShareExtensionDraftBlock(runs: [ShareExtensionDraftRun(text: "")])]
        : content.blocks,
      connectionId: identity.connectionId,
      createdAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000),
      id: id,
      productAccountId: catalog.productAccountId,
      profileId: profile.id,
      sendingIdentityId: identity.id
    )
    guard draft.inputByteCount <= ShareExtensionDraftPayload.maximumInputByteCount else {
      throw ShareExtensionInputError.totalSizeExceeded
    }
    return draft
  }

  private func makeContent(
    from inputs: [ShareExtensionInput]
  ) -> (assets: [ShareExtensionDraftAsset], blocks: [ShareExtensionDraftBlock]) {
    var assets: [ShareExtensionDraftAsset] = []
    var blocks: [ShareExtensionDraftBlock] = []
    for input in inputs {
      append(input, assets: &assets, blocks: &blocks)
    }
    return (assets, blocks)
  }

  private func append(
    _ input: ShareExtensionInput,
    assets: inout [ShareExtensionDraftAsset],
    blocks: inout [ShareExtensionDraftBlock]
  ) {
    switch input {
    case .text(let text):
      blocks += text.split(separator: "\n", omittingEmptySubsequences: false).map {
        ShareExtensionDraftBlock(runs: [ShareExtensionDraftRun(text: String($0))])
      }
    case .link(let url):
      blocks.append(
        ShareExtensionDraftBlock(
          runs: [ShareExtensionDraftRun(text: url.absoluteString, link: url.absoluteString)]
        )
      )
    case .image(let data, let filename, let mediaType):
      let asset = makeAsset(data, filename: filename, mediaType: mediaType, disposition: .inline)
      assets.append(asset)
      blocks.append(
        ShareExtensionDraftBlock(
          runs: [ShareExtensionDraftRun(text: "", inlineAssetId: asset.id)]
        )
      )
    case .file(let data, let filename, let mediaType):
      assets.append(
        makeAsset(data, filename: filename, mediaType: mediaType, disposition: .attachment)
      )
    }
  }

  private func makeAsset(
    _ data: Data,
    filename: String,
    mediaType: String,
    disposition: ShareExtensionDraftAsset.Disposition
  ) -> ShareExtensionDraftAsset {
    ShareExtensionDraftAsset(
      data: data,
      disposition: disposition,
      filename: filename,
      id: UUID(),
      mediaType: mediaType
    )
  }
}

/// Actionable failures produced while accepting host-app content.
enum ShareExtensionInputError: LocalizedError, Equatable {
  case emptyRequest
  case itemTooLarge(filename: String)
  case totalSizeExceeded
  case unsupportedItem

  var errorDescription: String? {
    switch self {
    case .emptyRequest:
      "Share text, a link, an image, or a file to create a Draft."
    case .itemTooLarge(let filename):
      "“\(filename)” is too large for the Share Extension. Add it from Unwired Mail instead."
    case .totalSizeExceeded:
      "These items are too large for the Share Extension. Add fewer items or use Unwired Mail."
    case .unsupportedItem:
      "This item is not supported. Share text, a link, an image, or a file."
    }
  }
}
