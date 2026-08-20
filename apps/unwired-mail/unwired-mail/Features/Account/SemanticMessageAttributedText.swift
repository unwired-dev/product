import Foundation
import SwiftUI

extension SemanticMessageDocument {
  /// Creates a supported semantic document while discarding unsupported attributed-text traits.
  init(attributedText: AttributedString) {
    let lines = attributedText.characters.split(
      separator: "\n",
      omittingEmptySubsequences: false
    )
    self.init(
      blocks: lines.enumerated().map { lineIndex, characters in
        let substring = AttributedString(
          attributedText[characters.startIndex..<characters.endIndex])
        let kind = Self.blockKind(in: substring, fallbackOrdinal: lineIndex + 1)
        let runs = substring.runs.map { run in
          let intent = run.inlinePresentationIntent ?? []
          return Run(
            String(substring[run.range].characters),
            isBold: intent.contains(.stronglyEmphasized),
            isCode: intent.contains(.code),
            isItalic: intent.contains(.emphasized),
            isStruckThrough: run.strikethroughStyle != nil,
            isUnderlined: run.underlineStyle != nil,
            link: run.link?.absoluteString
          )
        }
        return Block(kind: kind, runs: runs.isEmpty ? [Run("")] : runs)
      }
    )
  }

  /// Returns the SwiftUI attributed representation used only by the local editor.
  var attributedText: AttributedString {
    var result = AttributedString()
    for (index, block) in blocks.enumerated() {
      if index > 0 { result.append(AttributedString("\n")) }
      var line = AttributedString()
      for run in block.runs {
        var value = AttributedString(run.text)
        var intent: InlinePresentationIntent = []
        if run.isBold { intent.insert(.stronglyEmphasized) }
        if run.isCode { intent.insert(.code) }
        if run.isItalic { intent.insert(.emphasized) }
        value.inlinePresentationIntent = intent.isEmpty ? nil : intent
        value.strikethroughStyle = run.isStruckThrough ? .single : nil
        value.underlineStyle = run.isUnderlined ? .single : nil
        value.link = run.link.flatMap(URL.init(string:))
        line.append(value)
      }
      line.presentationIntent = Self.presentationIntent(for: block.kind, identity: index * 2)
      switch block.kind {
      case .codeBlock:
        line.font = .body.monospaced()
      case .heading(let level):
        line.font = level == 1 ? .title2 : (level == 2 ? .title3 : .headline)
      default:
        break
      }
      result.append(line)
    }
    return result
  }

  // swiftlint:disable:next cyclomatic_complexity
  private static func blockKind(
    in text: AttributedString,
    fallbackOrdinal: Int
  ) -> Block.Kind {
    let kinds = text.runs.compactMap(\.presentationIntent).flatMap(\.components).map(\.kind)
    if let heading = kinds.compactMap({ kind -> Int? in
      guard case .header(let level) = kind else { return nil }
      return level
    }).first {
      return .heading(level: min(max(heading, 1), 3))
    }
    if kinds.contains(where: { if case .codeBlock = $0 { true } else { false } }) {
      return .codeBlock
    }
    if kinds.contains(where: { if case .blockQuote = $0 { true } else { false } }) {
      return .blockquote
    }
    if kinds.contains(where: { if case .unorderedList = $0 { true } else { false } }) {
      return .bulletedListItem
    }
    if kinds.contains(where: { if case .orderedList = $0 { true } else { false } }) {
      let ordinal =
        kinds.compactMap { kind -> Int? in
          guard case .listItem(let ordinal) = kind else { return nil }
          return ordinal
        }.first ?? fallbackOrdinal
      return .numberedListItem(ordinal: ordinal)
    }
    return .paragraph
  }

  private static func presentationIntent(
    for kind: Block.Kind,
    identity: Int
  ) -> PresentationIntent {
    switch kind {
    case .blockquote:
      PresentationIntent(.blockQuote, identity: identity)
    case .bulletedListItem:
      PresentationIntent(
        .listItem(ordinal: 1),
        identity: identity + 1,
        parent: PresentationIntent(.unorderedList, identity: identity)
      )
    case .codeBlock:
      PresentationIntent(.codeBlock(languageHint: nil), identity: identity)
    case .heading(let level):
      PresentationIntent(.header(level: level), identity: identity)
    case .numberedListItem(let ordinal):
      PresentationIntent(
        .listItem(ordinal: ordinal),
        identity: identity + 1,
        parent: PresentationIntent(.orderedList, identity: identity)
      )
    case .paragraph:
      PresentationIntent(.paragraph, identity: identity)
    }
  }
}
