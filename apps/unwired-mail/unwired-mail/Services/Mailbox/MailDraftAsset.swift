import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// How an authored Draft asset appears in the delivered message.
enum MailDraftAssetDisposition: String, Codable, Sendable {
  case attachment
  case inline
}

/// One bounded, independently verifiable Draft-asset chunk.
struct MailDraftAssetChunk: Codable, Equatable, Sendable {
  static let maximumByteCount = 512 * 1_024

  let data: Data
  let index: Int
  let sha256Base64: String

  /// Creates one verified chunk at its stable position.
  init(data: Data, index: Int) {
    self.data = data
    self.index = index
    sha256Base64 = Data(SHA256.hash(data: data)).base64EncodedString()
  }

  var isValid: Bool {
    data.count <= Self.maximumByteCount
      && sha256Base64 == Data(SHA256.hash(data: data)).base64EncodedString()
  }
}

/// Authored attachment metadata plus locally available bounded chunks.
struct MailDraftAsset: Codable, Equatable, Identifiable, Sendable {
  let byteCount: Int
  var chunks: [MailDraftAssetChunk]
  let contentId: String
  var disposition: MailDraftAssetDisposition
  let filename: String
  let id: UUID
  let mediaType: String
  let sha256Base64: String
  let expectedChunkCount: Int

  /// Creates a complete local Draft asset from user-selected bytes.
  init(
    data: Data,
    filename: String,
    mediaType: String,
    disposition: MailDraftAssetDisposition = .attachment,
    id: UUID = UUID()
  ) {
    byteCount = data.count
    chunks = stride(from: 0, to: data.count, by: MailDraftAssetChunk.maximumByteCount)
      .enumerated().map { index, offset in
        MailDraftAssetChunk(
          data: data.subdata(
            in: offset..<min(offset + MailDraftAssetChunk.maximumByteCount, data.count)
          ),
          index: index
        )
      }
    contentId = "draft-asset-\(id.uuidString.lowercased())@unwired.mail"
    self.disposition = disposition
    self.filename = filename.isEmpty ? "Attachment" : filename
    self.id = id
    self.mediaType = mediaType.isEmpty ? "application/octet-stream" : mediaType
    sha256Base64 = Data(SHA256.hash(data: data)).base64EncodedString()
    expectedChunkCount = chunks.count
  }

  private init(copying asset: Self, chunks: [MailDraftAssetChunk]) {
    byteCount = asset.byteCount
    self.chunks = chunks
    contentId = asset.contentId
    disposition = asset.disposition
    filename = asset.filename
    id = asset.id
    mediaType = asset.mediaType
    sha256Base64 = asset.sha256Base64
    expectedChunkCount = asset.expectedChunkCount
  }

  var metadataOnly: Self { Self(copying: self, chunks: []) }

  func replacingChunks(_ chunks: [MailDraftAssetChunk]) -> Self {
    Self(copying: self, chunks: chunks)
  }

  func compressedImage(maxPixelSize: Int = 1_600, quality: Double = 0.72) -> Self? {
    guard mediaType.hasPrefix("image/"), let data,
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(
        source,
        0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
      )
    else { return nil }
    let encoded = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        encoded,
        UTType.jpeg.identifier as CFString,
        1,
        nil
      )
    else { return nil }
    CGImageDestinationAddImage(
      destination,
      image,
      [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
    )
    guard CGImageDestinationFinalize(destination), encoded.length < data.count else { return nil }
    let stem = (filename as NSString).deletingPathExtension
    return MailDraftAsset(
      data: encoded as Data,
      filename: "\(stem.isEmpty ? "Image" : stem).jpg",
      mediaType: "image/jpeg",
      disposition: disposition,
      id: id
    )
  }

  var data: Data? {
    let ordered = chunks.sorted { $0.index < $1.index }
    guard ordered.count == expectedChunkCount,
      ordered.enumerated().allSatisfy({ $0.offset == $0.element.index && $0.element.isValid })
    else { return nil }
    let data = ordered.reduce(into: Data()) { $0.append($1.data) }
    guard data.count == byteCount,
      sha256Base64 == Data(SHA256.hash(data: data)).base64EncodedString()
    else { return nil }
    return data
  }

  var isComplete: Bool { data != nil }

  /// Returns the conservative transfer-encoded byte contribution.
  var transferEncodedByteCount: Int {
    ((byteCount + 2) / 3) * 4 + ((byteCount + 56) / 57) * 2 + 512
  }
}

/// Provider-size preflight for a complete authored message.
enum MailDraftTransferBudget {
  static func estimatedByteCount(
    body: String,
    htmlBody: String,
    assets: [MailDraftAsset]
  ) -> Int {
    body.utf8.count + htmlBody.utf8.count
      + assets.reduce(2_048) { $0 + $1.transferEncodedByteCount }
  }

  static func knownLimit(for providerId: MailProviderId) -> Int? {
    switch providerId {
    case .gmail:
      25 * 1_024 * 1_024
    case .microsoftGraph:
      3 * 1_024 * 1_024
    default:
      nil
    }
  }
}

extension Array where Element == MailDraftAsset {
  /// Adds authored asset metadata to semantic inline-image references without moving them.
  func applyingInlineImageMetadata(to html: String) -> String {
    reduce(html) { result, asset in
      guard asset.disposition == .inline else { return result }
      let escapedName = asset.filename
        .replacing("&", with: "&amp;")
        .replacing("<", with: "&lt;")
        .replacing(">", with: "&gt;")
        .replacing("\"", with: "&quot;")
      return result.replacing(
        #"<img src="cid:\#(asset.contentId)" alt="Inline image">"#,
        with: #"<img src="cid:\#(asset.contentId)" alt="\#(escapedName)">"#
      )
    }
  }
}

extension MailShellCompositionDraft {
  var assetsAreReady: Bool {
    assets.allSatisfy(\.isComplete)
  }

  mutating func addAsset(_ asset: MailDraftAsset) {
    assets.append(asset)
  }

  mutating func removeAsset(_ assetId: UUID) {
    assets.removeAll { $0.id == assetId }
  }

  mutating func toggleAssetDisposition(_ assetId: UUID) {
    guard let index = assets.firstIndex(where: { $0.id == assetId }) else { return }
    assets[index].disposition = assets[index].disposition == .inline ? .attachment : .inline
  }

  mutating func compressImages() {
    assets = assets.map { $0.compressedImage() ?? $0 }
  }

  mutating func includeLocallyAvailableForwardAssets(from body: MailboxMessageBody) {
    let inlineAssets = body.inlineImages.map {
      MailDraftAsset(
        data: $0.data,
        filename: "Inline image",
        mediaType: $0.mimeType,
        disposition: .inline
      )
    }
    assets.append(contentsOf: inlineAssets)
    for asset in inlineAssets {
      document.blocks.append(.init(runs: [.init("", inlineAssetId: asset.id)]))
    }
    assets.append(
      contentsOf: body.attachments.compactMap { attachment in
        guard let data = attachment.presentationData else { return nil }
        return MailDraftAsset(
          data: data,
          filename: attachment.filename,
          mediaType: attachment.mimeType
        )
      }
    )
    omittedForwardAttachmentCount = body.attachments.filter { $0.presentationData == nil }.count
  }
}
