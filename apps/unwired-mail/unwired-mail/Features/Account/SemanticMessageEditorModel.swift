import Observation
import SwiftUI

// swiftlint:disable file_length

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
// swiftlint:disable:next type_body_length
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
    let source = SemanticMessageDocument(attributedText: attributedText)
    let converted = source.convertingInputShortcuts()
    guard converted != document else { return }
    recordUndo(document)
    redoDocuments.removeAll()
    document = converted
    if source != converted {
      let oldCount = attributedText.characters.count
      let newCount = converted.attributedText.characters.count
      let mappedOffsets = selectionOffsets.map { offsets in
        (
          Self.mapSelectionOffset(offsets.0, oldCount: oldCount, newCount: newCount),
          Self.mapSelectionOffset(offsets.1, oldCount: oldCount, newCount: newCount)
        )
      }
      replaceAttributedText(with: converted, selectionOffsets: mappedOffsets)
    }
  }

  /// Toggles one inline style across the current selection or typing attributes.
  func toggleInline(_ command: SemanticMessageInlineCommand) {
    let oldDocument = document
    let uniformlyEnabled = selectedRunsAllContain(command)
    attributedText.transformAttributes(in: &selection) { attributes in
      Self.setInline(
        command,
        enabled: uniformlyEnabled.map { !$0 },
        in: &attributes
      )
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

  /// Inserts one authored inline asset at the current editor selection.
  func insertInlineAsset(_ assetId: UUID) {
    let oldDocument = document
    var replacement = AttributedString("\u{FFFC}")
    replacement.link = URL(
      string: "unwired-inline-asset://\(assetId.uuidString.lowercased())"
    )
    switch selection.indices(in: attributedText) {
    case .insertionPoint(let index):
      attributedText.replaceSubrange(index..<index, with: replacement)
    case .ranges(let ranges):
      guard let first = ranges.ranges.first, let last = ranges.ranges.last else { return }
      attributedText.replaceSubrange(first.lowerBound..<last.upperBound, with: replacement)
    }
    finishCommand(previousDocument: oldDocument)
  }

  /// Removes the semantic reference for an asset that is no longer inline.
  func removeInlineAsset(_ assetId: UUID) {
    var updated = document
    for blockIndex in updated.blocks.indices {
      updated.blocks[blockIndex].runs.removeAll { $0.inlineAssetId == assetId }
      if updated.blocks[blockIndex].runs.isEmpty {
        updated.blocks[blockIndex].runs = [.init("")]
      }
    }
    guard updated != document else { return }
    let offsets = selectionOffsets
    recordUndo(document)
    redoDocuments.removeAll()
    document = updated
    replaceAttributedText(with: updated, selectionOffsets: offsets)
  }

  /// Appends semantic content while retaining every supported block and inline style.
  func insertAtEnd(_ insertedDocument: SemanticMessageDocument) {
    guard insertedDocument.plainText.isEmpty == false else { return }
    let previousDocument = document
    var updated = document
    if updated.plainText.isEmpty {
      updated = insertedDocument
    } else if updated.blocks.last?.kind == .paragraph,
      updated.blocks.last?.text.isEmpty == true
    {
      updated.append(contentsOf: insertedDocument)
    } else {
      updated.blocks.append(.init(runs: [.init("")]))
      updated.append(contentsOf: insertedDocument)
    }
    guard updated != previousDocument else { return }
    recordUndo(previousDocument)
    redoDocuments.removeAll()
    document = updated
    replaceAttributedText(with: updated, selectionOffsets: nil)
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
    let endOffset = offsets.1 > offsets.0 ? offsets.1 - 1 : offsets.1
    let end = text.prefix(endOffset).count(where: { $0 == "\n" })
    let upperBound = min(end + 1, document.blocks.count)
    return min(start, upperBound)..<upperBound
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

  private func selectedRunsAllContain(_ command: SemanticMessageInlineCommand) -> Bool? {
    guard case .ranges(let ranges) = selection.indices(in: attributedText),
      !ranges.ranges.isEmpty
    else { return nil }
    let selectedRuns = ranges.ranges.flatMap { attributedText[$0].runs }
    guard !selectedRuns.isEmpty else { return nil }
    return selectedRuns.allSatisfy { run in
      switch command {
      case .bold:
        run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
      case .code:
        run.inlinePresentationIntent?.contains(.code) == true
      case .italic:
        run.inlinePresentationIntent?.contains(.emphasized) == true
      case .strikethrough:
        run.strikethroughStyle != nil
      case .underline:
        run.underlineStyle != nil
      }
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

  private static func mapSelectionOffset(
    _ offset: Int,
    oldCount: Int,
    newCount: Int
  ) -> Int {
    max(0, newCount - max(0, oldCount - offset))
  }

  private static func setInline(
    _ command: SemanticMessageInlineCommand,
    enabled: Bool?,
    in attributes: inout AttributeContainer
  ) {
    switch command {
    case .bold:
      attributes.inlinePresentationIntent = setting(
        .stronglyEmphasized,
        enabled: enabled,
        in: attributes.inlinePresentationIntent
      )
    case .code:
      attributes.inlinePresentationIntent = setting(
        .code,
        enabled: enabled,
        in: attributes.inlinePresentationIntent
      )
    case .italic:
      attributes.inlinePresentationIntent = setting(
        .emphasized,
        enabled: enabled,
        in: attributes.inlinePresentationIntent
      )
    case .strikethrough:
      let shouldEnable = enabled ?? (attributes.strikethroughStyle == nil)
      attributes.strikethroughStyle = shouldEnable ? .single : nil
    case .underline:
      let shouldEnable = enabled ?? (attributes.underlineStyle == nil)
      attributes.underlineStyle = shouldEnable ? .single : nil
    }
  }

  private static func setting(
    _ style: InlinePresentationIntent,
    enabled: Bool?,
    in current: InlinePresentationIntent?
  ) -> InlinePresentationIntent? {
    guard let enabled else { return toggling(style, in: current) }
    var updated = current ?? []
    if enabled {
      updated.insert(style)
    } else {
      updated.remove(style)
    }
    return updated.isEmpty ? nil : updated
  }
}
