import CoreFoundation
import Foundation
import ImageIO
import SwiftSoup

enum InlineImageDimensionPolicy {
  static func hasExpandingMinimum(_ dimension: String, in element: Element) -> Bool {
    guard let value = value("min-\(dimension)", in: element) else { return false }
    let isPositiveLength =
      value.range(
        of: #"^\+?(?:\d+(?:\.\d*)?|\.\d+)"# + CSSLengthValuePolicy.unitPattern + "$",
        options: [.regularExpression, .caseInsensitive]
      ) != nil
      || MessageHTMLHiddenStylePatterns.simpleCalculatedPixelLengthValue(value).map { $0 > 0 }
        == true
    let isOnePixel = MessageHTMLHiddenStylePatterns.isOnePixelLengthValue(value)
    return isPositiveLength && !isOnePixel
      && !MessageHTMLHiddenStylePatterns.isZeroLengthValue(value)
  }

  static func value(_ property: String, in element: Element) -> String? {
    guard let style = try? element.attr("style") else { return nil }
    var normalValue: String?
    var importantValue: String?
    for declaration in style.split(separator: ";") {
      let parts = declaration.split(separator: ":", maxSplits: 1)
      guard parts.count == 2,
        parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
          .caseInsensitiveCompare(property) == .orderedSame
      else {
        continue
      }
      let rawValue = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
      let isImportant =
        rawValue.range(
          of: #"\s*!important\s*$"#,
          options: [.regularExpression, .caseInsensitive]
        ) != nil
      let value = rawValue.replacingOccurrences(
        of: #"\s*!important\s*$"#,
        with: "",
        options: [.regularExpression, .caseInsensitive]
      )
      guard isValidValue(value) else { continue }
      if isImportant {
        importantValue = value
      } else {
        normalValue = value
      }
    }
    return importantValue ?? normalValue
  }

  private static func isValidValue(_ value: String) -> Bool {
    let normalized = value.lowercased()
    if [
      "auto", "fit-content", "inherit", "initial", "max-content", "min-content",
      "revert", "revert-layer", "stretch", "unset",
    ].contains(normalized) {
      return true
    }
    if MessageHTMLHiddenStylePatterns.isZeroLengthValue(normalized)
      || MessageHTMLHiddenStylePatterns.isOnePixelLengthValue(normalized)
      || MessageHTMLHiddenStylePatterns.simpleCalculatedPixelLengthValue(normalized) != nil
    {
      return true
    }
    return normalized.range(
      of: "^(?:" + CSSLengthValuePolicy.zeroLengthPattern + #"|\+?(?:\d+(?:\.\d*)?|\.\d+)"#
        + CSSLengthValuePolicy.unitPattern + ")$",
      options: .regularExpression
    ) != nil
  }
}

struct RemoteMessageContentAdmission {
  let image: RemoteMessageImage
  let pixelCount: Int
}

struct RemoteMessageContentLoadProgress {
  var attemptedIdentifiers = Set<String>()
  var attemptedImageCount = 0
  var images: [RemoteMessageImage] = []
  var loadedByteCount = 0
  var loadedPixelCount = 0
  var receivedByteCount = 0
}

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
      CGImageSourceGetStatus(source) == .statusComplete,
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
