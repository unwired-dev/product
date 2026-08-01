import CoreFoundation
import Foundation
import ImageIO
import SwiftSoup

// swiftlint:disable:next type_body_length
enum InlineImageDimensionPolicy {
  private static let maximumResolutionDepth = 64
  private static let maximumResolutionWork = 8_192

  static func isOnePixel(_ value: String, in element: Element) -> Bool {
    var remainingWork = maximumResolutionWork
    let fontSizePixels = inheritedFontSizePixels(in: element, remainingWork: &remainingWork)
    return MessageHTMLHiddenStylePatterns.isOnePixelLengthValue(
      value,
      fontSizePixels: fontSizePixels
    )
  }

  static func isOnePixel(
    _ value: String,
    dimension: String,
    in element: Element
  ) -> Bool {
    var remainingWork = maximumResolutionWork
    return resolvedDimensionPixels(
      value,
      dimension: dimension,
      in: element,
      remainingDepth: maximumResolutionDepth,
      remainingWork: &remainingWork
    ).map { abs($0 - 1) < 0.000_000_001 } == true
  }

  static func hasOnePixelUsedDimension(_ dimension: String, in element: Element) -> Bool {
    var remainingWork = maximumResolutionWork
    return resolvedUsedDimensionPixels(
      dimension: dimension,
      in: element,
      remainingDepth: maximumResolutionDepth,
      remainingWork: &remainingWork
    ).map { abs($0 - 1) < 0.000_000_001 } == true
  }

  private static func resolvedDimensionPixels(
    _ value: String,
    dimension: String,
    in element: Element,
    remainingDepth: Int,
    remainingWork: inout Int
  ) -> Double? {
    guard remainingDepth > 0, remainingWork > 0 else { return nil }
    remainingWork -= 1
    if MessageHTMLHiddenStylePatterns.isZeroLengthValue(value) { return 0 }
    if let pixels = MessageHTMLHiddenStylePatterns.pixelLengthValue(
      value,
      fontSizePixels: inheritedFontSizePixels(in: element, remainingWork: &remainingWork)
    ) {
      return pixels
    }
    let normalized = value.lowercased()
    if normalized == "inherit", let parent = element.parent() {
      return resolvedUsedDimensionPixels(
        dimension: dimension,
        in: parent,
        remainingDepth: remainingDepth - 1,
        remainingWork: &remainingWork
      )
    }
    guard normalized.hasSuffix("%"),
      let percentage = Double(normalized.dropLast()),
      let parent = containingBlockAncestor(of: element, remainingDepth: remainingDepth),
      let containingPixels =
        resolvedUsedDimensionPixels(
          dimension: dimension,
          in: parent,
          remainingDepth: remainingDepth - 1,
          remainingWork: &remainingWork
        )
        ?? (dimension == "width"
          ? resolvedAutoNormalFlowBlockWidth(
            in: parent,
            remainingDepth: remainingDepth - 1,
            remainingWork: &remainingWork
          ) : nil)
    else { return nil }
    return containingPixels * percentage / 100
  }

  private static func resolvedUsedDimensionPixels(
    dimension: String,
    in element: Element,
    remainingDepth: Int,
    remainingWork: inout Int
  ) -> Double? {
    guard let declaredValue = value(dimension, in: element),
      var pixels = resolvedDimensionPixels(
        declaredValue,
        dimension: dimension,
        in: element,
        remainingDepth: remainingDepth,
        remainingWork: &remainingWork
      )
    else { return nil }
    if let maximumValue = value("max-\(dimension)", in: element),
      let maximumPixels = resolvedDimensionPixels(
        maximumValue,
        dimension: dimension,
        in: element,
        remainingDepth: remainingDepth,
        remainingWork: &remainingWork
      )
    {
      pixels = min(pixels, maximumPixels)
    }
    if let minimumValue = value("min-\(dimension)", in: element),
      let minimumPixels = resolvedDimensionPixels(
        minimumValue,
        dimension: dimension,
        in: element,
        remainingDepth: remainingDepth,
        remainingWork: &remainingWork
      )
    {
      pixels = max(pixels, minimumPixels)
    }
    return pixels
  }

  private static func resolvedAutoNormalFlowBlockWidth(
    in element: Element,
    remainingDepth: Int,
    remainingWork: inout Int
  ) -> Double? {
    guard hasAutoNormalFlowBlockWidth(element),
      let parent = containingBlockAncestor(of: element, remainingDepth: remainingDepth)
    else { return nil }
    guard
      var pixels = resolvedUsedDimensionPixels(
        dimension: "width",
        in: parent,
        remainingDepth: remainingDepth - 1,
        remainingWork: &remainingWork
      )
    else { return nil }
    let declarations = MessageHTMLHiddenStylePatterns.declarations(
      in: (try? element.attr("style")) ?? ""
    )
    pixels -= MessageHTMLHiddenStylePatterns.horizontalInsetPixels(
      in: declarations,
      fontSizePixels: inheritedFontSizePixels(in: element, remainingWork: &remainingWork)
    )
    pixels = max(0, pixels)
    if let maximumValue = value("max-width", in: element),
      let maximumPixels = resolvedDimensionPixels(
        maximumValue,
        dimension: "width",
        in: element,
        remainingDepth: remainingDepth,
        remainingWork: &remainingWork
      )
    {
      pixels = min(pixels, maximumPixels)
    }
    if let minimumValue = value("min-width", in: element),
      let minimumPixels = resolvedDimensionPixels(
        minimumValue,
        dimension: "width",
        in: element,
        remainingDepth: remainingDepth,
        remainingWork: &remainingWork
      )
    {
      pixels = max(pixels, minimumPixels)
    }
    return pixels
  }

  private static func hasAutoNormalFlowBlockWidth(_ element: Element) -> Bool {
    if let declaredWidth = value("width", in: element),
      !["auto", "initial", "revert", "revert-layer", "unset"].contains(declaredWidth.lowercased())
    {
      return false
    }
    let declarations = MessageHTMLHiddenStylePatterns.declarations(
      in: (try? element.attr("style")) ?? ""
    )
    if let display = MessageHTMLHiddenStylePatterns.effectiveValue(
      "display",
      in: declarations,
      where: MessageHTMLHiddenStylePatterns.isDisplayValue
    ) {
      let components = display.split(whereSeparator: \Character.isWhitespace).map(String.init)
      return ["block", "flow-root", "list-item"].contains(display)
        || components.first == "block"
    }
    return [
      "address", "article", "aside", "blockquote", "dd", "div", "dl", "dt", "fieldset",
      "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6",
      "header", "hgroup", "hr", "main", "nav", "ol", "p", "pre", "section", "ul",
    ].contains(element.tagName().lowercased())
  }

  private static func containingBlockAncestor(
    of element: Element,
    remainingDepth: Int
  ) -> Element? {
    guard remainingDepth > 0, let parent = element.parent() else { return nil }
    guard isOrdinaryInlineBox(parent) else { return parent }
    return containingBlockAncestor(of: parent, remainingDepth: remainingDepth - 1)
  }

  private static func isOrdinaryInlineBox(_ element: Element) -> Bool {
    !MessageHTMLHiddenStylePatterns.dimensionsApply(to: element)
  }

  private static func inheritedFontSizePixels(
    in element: Element,
    remainingDepth: Int = maximumResolutionDepth,
    remainingWork: inout Int
  ) -> Double? {
    guard remainingDepth > 0, remainingWork > 0 else { return nil }
    remainingWork -= 1
    guard let fontSize = value("font-size", in: element) else {
      return element.parent().flatMap {
        inheritedFontSizePixels(
          in: $0,
          remainingDepth: remainingDepth - 1,
          remainingWork: &remainingWork
        )
      } ?? CSSLengthValuePolicy.initialFontSizePixels
    }
    let normalized = fontSize.lowercased()
    if let pixels = MessageHTMLHiddenStylePatterns.pixelLengthValue(
      normalized,
      fontSizePixels: nil
    ) {
      return pixels
    }
    if normalized == "initial" { return CSSLengthValuePolicy.initialFontSizePixels }
    if normalized == "inherit" || normalized == "unset" {
      return element.parent().flatMap {
        inheritedFontSizePixels(
          in: $0,
          remainingDepth: remainingDepth - 1,
          remainingWork: &remainingWork
        )
      } ?? CSSLengthValuePolicy.initialFontSizePixels
    }
    let inheritedPixels =
      element.parent().flatMap {
        inheritedFontSizePixels(
          in: $0,
          remainingDepth: remainingDepth - 1,
          remainingWork: &remainingWork
        )
      } ?? CSSLengthValuePolicy.initialFontSizePixels
    if normalized.hasSuffix("%"), let percentage = Double(normalized.dropLast()) {
      return inheritedPixels * percentage / 100
    }
    guard normalized.hasSuffix("em"),
      let multiplier = Double(normalized.dropLast(2))
    else { return nil }
    return inheritedPixels * multiplier
  }

  static func hasExpandingMinimum(_ dimension: String, in element: Element) -> Bool {
    resolvedMinimumPixels(dimension, in: element).map { $0 > 1 } == true
  }

  static func hasPositiveMinimum(_ dimension: String, in element: Element) -> Bool {
    resolvedMinimumPixels(dimension, in: element).map { $0 > 0 } == true
  }

  private static func resolvedMinimumPixels(_ dimension: String, in element: Element) -> Double? {
    guard let value = value("min-\(dimension)", in: element) else { return nil }
    var remainingWork = maximumResolutionWork
    return resolvedDimensionPixels(
      value,
      dimension: dimension,
      in: element,
      remainingDepth: maximumResolutionDepth,
      remainingWork: &remainingWork
    )
  }

  static func value(_ property: String, in element: Element) -> String? {
    guard let style = try? element.attr("style") else { return nil }
    return MessageHTMLHiddenStylePatterns.effectiveValue(
      property.lowercased(),
      in: MessageHTMLHiddenStylePatterns.declarations(in: style),
      where: isValidValue
    )
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
