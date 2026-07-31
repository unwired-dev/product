import CoreFoundation
import Foundation
import ImageIO

enum MailboxMessageImagePolicy {
  static let maximumImageAttemptCount = 20
  static let maximumImageByteCount = 5 * 1_024 * 1_024
  static let maximumImageDimension = 8_192
  static let maximumImagePixelCount = 16 * 1_024 * 1_024
  static let maximumTotalByteCount = 20 * 1_024 * 1_024
  static let maximumTotalPixelCount = 32 * 1_024 * 1_024

  static func normalizedSupportedMIMEType(_ mimeType: String?) -> String? {
    guard let mimeType else { return nil }
    let normalized = mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return ["image/gif", "image/jpeg", "image/png", "image/webp"].contains(normalized)
      ? normalized
      : nil
  }

  static func admittedPixelCount(
    _ data: Data,
    mimeType: String,
    remainingByteCount: Int,
    remainingPixelCount: Int
  ) -> Int? {
    guard data.count <= maximumImageByteCount,
      data.count <= remainingByteCount,
      hasValidSignature(data, mimeType: mimeType)
    else {
      return nil
    }
    let options = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithData(data as CFData, options),
      CGImageSourceGetCount(source) == 1,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options)
        as? [CFString: Any],
      let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
      let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
      width > 0,
      height > 0,
      width <= maximumImageDimension,
      height <= maximumImageDimension,
      width <= maximumImagePixelCount / height,
      width * height <= remainingPixelCount
    else {
      return nil
    }
    return width * height
  }

  private static func hasValidSignature(_ data: Data, mimeType: String) -> Bool {
    switch mimeType {
    case "image/gif":
      return data.starts(with: Data("GIF87a".utf8)) || data.starts(with: Data("GIF89a".utf8))
    case "image/jpeg":
      return data.starts(with: Data([0xFF, 0xD8, 0xFF]))
    case "image/png":
      return data.starts(with: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
    case "image/webp":
      return data.count >= 12
        && data.starts(with: Data("RIFF".utf8))
        && Data(data[8..<12]) == Data("WEBP".utf8)
    default:
      return false
    }
  }
}
