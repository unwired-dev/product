import SwiftUI
import UIKit

enum SemanticMessageNativeText {
  static func semanticText(from nativeText: NSAttributedString) -> AttributedString {
    var result = AttributedString(nativeText.string)
    nativeText.enumerateAttributes(
      in: NSRange(location: 0, length: nativeText.length)
    ) { attributes, range, _ in
      let characterRange = characterRange(range, in: nativeText.string)
      guard characterRange.isEmpty == false else { return }
      let lower = result.characters.index(
        result.startIndex,
        offsetBy: characterRange.lowerBound
      )
      let upper = result.characters.index(
        result.startIndex,
        offsetBy: characterRange.upperBound
      )
      var inlineIntent: InlinePresentationIntent = []
      if attributes[.semanticBold] as? Bool == true {
        inlineIntent.insert(.stronglyEmphasized)
      }
      if attributes[.semanticCode] as? Bool == true { inlineIntent.insert(.code) }
      if attributes[.semanticItalic] as? Bool == true {
        inlineIntent.insert(.emphasized)
      }
      result[lower..<upper].inlinePresentationIntent =
        inlineIntent.isEmpty ? nil : inlineIntent
      result[lower..<upper].strikethroughStyle =
        attributes[.strikethroughStyle] == nil ? nil : .single
      result[lower..<upper].underlineStyle =
        attributes[.underlineStyle] == nil ? nil : .single
      if let url = attributes[.link] as? URL {
        result[lower..<upper].link = url
      } else if let destination = attributes[.link] as? String {
        result[lower..<upper].link = URL(string: destination)
      }
    }
    return result
  }

  static func renderedText(for document: SemanticMessageDocument) -> NSAttributedString {
    let result = NSMutableAttributedString()
    for (blockIndex, block) in document.blocks.enumerated() {
      if blockIndex > 0 { result.append(NSAttributedString(string: "\n")) }
      let blockStart = result.length
      for run in block.runs {
        let value = run.inlineAssetId == nil ? run.text : "\u{FFFC}"
        let attributes = runAttributes(run, blockKind: block.kind)
        result.append(NSAttributedString(string: value, attributes: attributes))
      }
      let blockRange = NSRange(location: blockStart, length: result.length - blockStart)
      if blockRange.length > 0 {
        result.addAttribute(
          .paragraphStyle,
          value: paragraphStyle(for: block.kind),
          range: blockRange
        )
        if case .codeBlock = block.kind {
          result.addAttribute(
            .backgroundColor,
            value: UIColor.secondarySystemBackground,
            range: blockRange
          )
        }
      }
    }
    return result
  }

  static func typingAttributes(
    for document: SemanticMessageDocument,
    selection: NSRange,
    text: String
  ) -> [NSAttributedString.Key: Any] {
    let blockIndex = min(
      text.utf16.prefix(selection.location).count(where: { $0 == 10 }),
      document.blocks.count - 1
    )
    let block = document.blocks[max(0, blockIndex)]
    var attributes = runAttributes(block.runs.last ?? .init(""), blockKind: block.kind)
    attributes[.paragraphStyle] = paragraphStyle(for: block.kind)
    return attributes
  }

  static func characterRange(_ range: NSRange, in text: String) -> Range<Int> {
    guard let stringRange = Range(range, in: text) else {
      let end = text.count
      return end..<end
    }
    let lower = text.distance(from: text.startIndex, to: stringRange.lowerBound)
    let upper = text.distance(from: text.startIndex, to: stringRange.upperBound)
    return lower..<upper
  }

  static func nativeOffset(forCharacterOffset offset: Int, in text: String) -> Int {
    let characterOffset = min(max(offset, 0), text.count)
    let index = text.index(text.startIndex, offsetBy: characterOffset)
    return index.utf16Offset(in: text)
  }

  static func nativeSelection(
    _ selection: AttributedTextSelection,
    in text: AttributedString
  ) -> NSRange {
    let offsets: Range<Int>
    switch selection.indices(in: text) {
    case .insertionPoint(let index):
      let offset = text.characters.distance(from: text.startIndex, to: index)
      offsets = offset..<offset
    case .ranges(let ranges):
      guard let first = ranges.ranges.first, let last = ranges.ranges.last else {
        return NSRange(location: text.characters.count, length: 0)
      }
      let lower = text.characters.distance(from: text.startIndex, to: first.lowerBound)
      let upper = text.characters.distance(from: text.startIndex, to: last.upperBound)
      offsets = lower..<upper
    }
    let string = String(text.characters)
    let lower = string.index(string.startIndex, offsetBy: offsets.lowerBound)
    let upper = string.index(string.startIndex, offsetBy: offsets.upperBound)
    let location = lower.utf16Offset(in: string)
    return NSRange(location: location, length: upper.utf16Offset(in: string) - location)
  }

  private static func runAttributes(
    _ run: SemanticMessageDocument.Run,
    blockKind: SemanticMessageDocument.Block.Kind
  ) -> [NSAttributedString.Key: Any] {
    var attributes: [NSAttributedString.Key: Any] = [
      .font: font(for: blockKind, run: run),
      .foregroundColor: UIColor.label,
    ]
    if run.isBold { attributes[.semanticBold] = true }
    if run.isCode { attributes[.semanticCode] = true }
    if run.isItalic { attributes[.semanticItalic] = true }
    if run.isStruckThrough { attributes[.strikethroughStyle] = 1 }
    if run.isUnderlined { attributes[.underlineStyle] = 1 }
    if let assetId = run.inlineAssetId,
      let url = URL(string: "unwired-inline-asset://\(assetId.uuidString.lowercased())")
    {
      attributes[.link] = url
    } else if let link = run.link, let url = URL(string: link) {
      attributes[.link] = url
    }
    return attributes
  }

  private static func font(
    for blockKind: SemanticMessageDocument.Block.Kind,
    run: SemanticMessageDocument.Run
  ) -> UIFont {
    let baseFont: UIFont =
      switch blockKind {
      case .codeBlock:
        UIFont.preferredFont(forTextStyle: .body)
      case .heading(let level):
        UIFont.preferredFont(
          forTextStyle: level == 1 ? .title2 : (level == 2 ? .title3 : .headline)
        )
      default:
        UIFont.preferredFont(forTextStyle: .body)
      }
    var traits: UIFontDescriptor.SymbolicTraits = []
    if run.isBold { traits.insert(.traitBold) }
    if run.isItalic { traits.insert(.traitItalic) }
    if run.isCode || blockKind == .codeBlock { traits.insert(.traitMonoSpace) }
    guard traits.isEmpty == false,
      let descriptor = baseFont.fontDescriptor.withSymbolicTraits(traits)
    else { return baseFont }
    return UIFont(descriptor: descriptor, size: 0)
  }

  private static func paragraphStyle(
    for blockKind: SemanticMessageDocument.Block.Kind
  ) -> NSParagraphStyle {
    let style = NSMutableParagraphStyle()
    switch blockKind {
    case .blockquote:
      style.firstLineHeadIndent = 20
      style.headIndent = 20
    case .bulletedListItem, .numberedListItem:
      style.firstLineHeadIndent = 28
      style.headIndent = 28
    case .codeBlock:
      style.firstLineHeadIndent = 8
      style.headIndent = 8
    case .heading, .paragraph:
      break
    }
    return style
  }
}

extension NSAttributedString.Key {
  fileprivate static let semanticBold = NSAttributedString.Key("unwired.semantic.bold")
  fileprivate static let semanticCode = NSAttributedString.Key("unwired.semantic.code")
  fileprivate static let semanticItalic = NSAttributedString.Key("unwired.semantic.italic")
}
