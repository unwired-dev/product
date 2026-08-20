import Observation
import SwiftUI

/// The block presentations exposed by toolbar, context-menu, and keyboard commands.
enum SemanticMessageBlockCommand: String, CaseIterable, Identifiable {
  case blockquote
  case bulletedList
  case codeBlock
  case heading1
  case heading2
  case heading3
  case numberedList
  case paragraph

  var id: String { rawValue }

  var title: String {
    switch self {
    case .blockquote: "Blockquote"
    case .bulletedList: "Bulleted List"
    case .codeBlock: "Code Block"
    case .heading1: "Heading 1"
    case .heading2: "Heading 2"
    case .heading3: "Heading 3"
    case .numberedList: "Numbered List"
    case .paragraph: "Paragraph"
    }
  }

  var systemImage: String {
    switch self {
    case .blockquote: "text.quote"
    case .bulletedList: "list.bullet"
    case .codeBlock: "chevron.left.forwardslash.chevron.right"
    case .heading1, .heading2, .heading3: "textformat.size"
    case .numberedList: "list.number"
    case .paragraph: "paragraphsign"
    }
  }

  fileprivate func kind(ordinal: Int) -> SemanticMessageDocument.Block.Kind {
    switch self {
    case .blockquote: .blockquote
    case .bulletedList: .bulletedListItem
    case .codeBlock: .codeBlock
    case .heading1: .heading(level: 1)
    case .heading2: .heading(level: 2)
    case .heading3: .heading(level: 3)
    case .numberedList: .numberedListItem(ordinal: ordinal)
    case .paragraph: .paragraph
    }
  }
}

/// The selection-based inline presentations supported by the semantic document.
enum SemanticMessageInlineCommand: String, CaseIterable, Identifiable {
  case bold
  case code
  case italic
  case strikethrough
  case underline

  var id: String { rawValue }

  var title: String {
    switch self {
    case .bold: "Bold"
    case .code: "Inline Code"
    case .italic: "Italic"
    case .strikethrough: "Strikethrough"
    case .underline: "Underline"
    }
  }

  var systemImage: String {
    switch self {
    case .bold: "bold"
    case .code: "chevron.left.forwardslash.chevron.right"
    case .italic: "italic"
    case .strikethrough: "strikethrough"
    case .underline: "underline"
    }
  }
}

/// Owns rich-editor selection, semantic conversion, and bounded undo history.
@MainActor
@Observable
final class SemanticMessageEditorModel {
  private static let historyLimit = 100

  var attributedText: AttributedString
  private(set) var document: SemanticMessageDocument
  var selection: AttributedTextSelection

  private var ignoredTextSnapshot: AttributedString?
  private var redoDocuments: [SemanticMessageDocument] = []
  private var undoDocuments: [SemanticMessageDocument] = []

  /// Creates an editor for one semantic document.
  init(document: SemanticMessageDocument) {
    let initialText = document.attributedText
    self.document = document
    attributedText = initialText
    selection = AttributedTextSelection(insertionPoint: initialText.endIndex)
  }

  var canRedo: Bool { !redoDocuments.isEmpty }
  var canUndo: Bool { !undoDocuments.isEmpty }

  /// Converts one direct TextEditor mutation into the supported semantic vocabulary.
  func textDidChange() {
    if ignoredTextSnapshot == attributedText {
      ignoredTextSnapshot = nil
      return
    }
    let converted = SemanticMessageDocument(attributedText: attributedText)
      .convertingInputShortcuts()
    guard converted != document else { return }
    recordUndo(document)
    redoDocuments.removeAll()
    document = converted
    if SemanticMessageDocument(attributedText: attributedText) != converted {
      replaceAttributedText(with: converted, selectionOffsets: nil)
    }
  }

  /// Toggles one inline style across the current selection or typing attributes.
  func toggleInline(_ command: SemanticMessageInlineCommand) {
    let oldDocument = document
    attributedText.transformAttributes(in: &selection) { attributes in
      switch command {
      case .bold:
        attributes.inlinePresentationIntent = Self.toggling(
          .stronglyEmphasized,
          in: attributes.inlinePresentationIntent
        )
      case .code:
        attributes.inlinePresentationIntent = Self.toggling(
          .code,
          in: attributes.inlinePresentationIntent
        )
      case .italic:
        attributes.inlinePresentationIntent = Self.toggling(
          .emphasized,
          in: attributes.inlinePresentationIntent
        )
      case .strikethrough:
        attributes.strikethroughStyle = attributes.strikethroughStyle == nil ? .single : nil
      case .underline:
        attributes.underlineStyle = attributes.underlineStyle == nil ? .single : nil
      }
    }
    finishCommand(previousDocument: oldDocument)
  }

  /// Applies one block style to every block intersecting the current selection.
  func applyBlock(_ command: SemanticMessageBlockCommand) {
    let offsets = selectionOffsets
    let selectedBlocks = selectedBlockRange
    guard !selectedBlocks.isEmpty else { return }
    var updated = document
    for (offset, index) in selectedBlocks.enumerated() where updated.blocks.indices.contains(index)
    {
      updated.blocks[index].kind = command.kind(ordinal: offset + 1)
    }
    guard updated != document else { return }
    recordUndo(document)
    redoDocuments.removeAll()
    document = updated
    replaceAttributedText(with: updated, selectionOffsets: offsets)
  }

  /// Applies a validated HTTP, HTTPS, or mail link to the current selection.
  func applyLink(_ destination: String) {
    guard let url = URL(string: destination),
      let scheme = url.scheme?.lowercased(),
      ["http", "https", "mailto"].contains(scheme)
    else { return }
    let oldDocument = document
    attributedText.transformAttributes(in: &selection) { attributes in
      attributes.link = url
    }
    finishCommand(previousDocument: oldDocument)
  }

  /// Restores the previous semantic snapshot.
  func undo() {
    guard let previous = undoDocuments.popLast() else { return }
    redoDocuments.append(document)
    document = previous
    replaceAttributedText(with: previous, selectionOffsets: nil)
  }

  /// Restores the next semantic snapshot after an undo.
  func redo() {
    guard let next = redoDocuments.popLast() else { return }
    recordUndo(document)
    document = next
    replaceAttributedText(with: next, selectionOffsets: nil)
  }

  private var selectedBlockRange: Range<Int> {
    let offsets = selectionOffsets ?? (0, 0)
    let text = String(attributedText.characters)
    let start = text.prefix(offsets.0).count(where: { $0 == "\n" })
    let end = text.prefix(offsets.1).count(where: { $0 == "\n" })
    return start..<(min(end + 1, document.blocks.count))
  }

  private var selectionOffsets: (Int, Int)? {
    switch selection.indices(in: attributedText) {
    case .insertionPoint(let index):
      let offset = attributedText.characters.distance(
        from: attributedText.startIndex,
        to: index
      )
      return (offset, offset)
    case .ranges(let ranges):
      guard let first = ranges.ranges.first, let last = ranges.ranges.last else { return nil }
      return (
        attributedText.characters.distance(
          from: attributedText.startIndex,
          to: first.lowerBound
        ),
        attributedText.characters.distance(
          from: attributedText.startIndex,
          to: last.upperBound
        )
      )
    }
  }

  private func finishCommand(previousDocument: SemanticMessageDocument) {
    let updated = SemanticMessageDocument(attributedText: attributedText)
    guard updated != previousDocument else { return }
    recordUndo(previousDocument)
    redoDocuments.removeAll()
    document = updated
  }

  private func recordUndo(_ value: SemanticMessageDocument) {
    undoDocuments.append(value)
    if undoDocuments.count > Self.historyLimit {
      undoDocuments.removeFirst(undoDocuments.count - Self.historyLimit)
    }
  }

  private func replaceAttributedText(
    with document: SemanticMessageDocument,
    selectionOffsets: (Int, Int)?
  ) {
    let replacement = document.attributedText
    ignoredTextSnapshot = replacement
    attributedText = replacement
    guard let selectionOffsets else {
      selection = AttributedTextSelection(insertionPoint: replacement.endIndex)
      return
    }
    let lowerOffset = min(selectionOffsets.0, replacement.characters.count)
    let upperOffset = min(max(selectionOffsets.1, lowerOffset), replacement.characters.count)
    let lower = replacement.characters.index(replacement.startIndex, offsetBy: lowerOffset)
    let upper = replacement.characters.index(replacement.startIndex, offsetBy: upperOffset)
    selection =
      lower == upper
      ? AttributedTextSelection(insertionPoint: lower)
      : AttributedTextSelection(range: lower..<upper)
  }

  private static func toggling(
    _ style: InlinePresentationIntent,
    in current: InlinePresentationIntent?
  ) -> InlinePresentationIntent? {
    var updated = current ?? []
    if updated.contains(style) {
      updated.remove(style)
    } else {
      updated.insert(style)
    }
    return updated.isEmpty ? nil : updated
  }
}
