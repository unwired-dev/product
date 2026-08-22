import Foundation

/// An encrypted, device-local Draft waiting for import by the containing app.
struct ShareExtensionDraftPayload: Codable, Equatable, Identifiable, Sendable {
  static let maximumInputByteCount = 40 * 1_024 * 1_024

  let assets: [ShareExtensionDraftAsset]
  let blocks: [ShareExtensionDraftBlock]
  let connectionId: String
  let createdAtMilliseconds: Int64
  let id: UUID
  let productAccountId: String
  let profileId: String
  let sendingIdentityId: String

  /// Returns the shared content size before encrypted JSON framing.
  var inputByteCount: Int {
    assets.reduce(0) { $0 + $1.data.count }
      + blocks.reduce(0) { total, block in
        total + block.runs.reduce(0) { $0 + $1.text.utf8.count }
      }
  }
}

/// One semantic paragraph in a shared Draft.
struct ShareExtensionDraftBlock: Codable, Equatable, Sendable {
  let runs: [ShareExtensionDraftRun]
}

/// One text, link, or Inline Image run in a shared Draft paragraph.
struct ShareExtensionDraftRun: Codable, Equatable, Sendable {
  let inlineAssetId: UUID?
  let link: String?
  let text: String

  /// Creates one validated semantic run.
  init(text: String, link: String? = nil, inlineAssetId: UUID? = nil) {
    self.inlineAssetId = inlineAssetId
    self.link = link
    self.text = text
  }
}

/// One complete shared image or file preserved for normal Draft import.
struct ShareExtensionDraftAsset: Codable, Equatable, Identifiable, Sendable {
  enum Disposition: String, Codable, Sendable {
    case attachment
    case inline
  }

  let data: Data
  let disposition: Disposition
  let filename: String
  let id: UUID
  let mediaType: String
}
