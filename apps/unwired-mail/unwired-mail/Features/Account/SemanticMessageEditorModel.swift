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

  private struct InputShortcutConversion {
    let converted: SemanticMessageDocument
    let source: SemanticMessageDocument
  }

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

  /// Returns the slash query at the insertion point when it begins the current block.
  var slashCommandContext: SemanticMessageSlashCommand.Context? {
    guard let offsets = selectionOffsets, offsets.0 == offsets.1 else { return nil }
    let characters = Array(String(attributedText.characters))
    let caretOffset = min(offsets.0, characters.count)
    let blockStart =
      characters[..<caretOffset].lastIndex(of: "\n").map { $0 + 1 } ?? 0
    let blockPrefix = characters[blockStart..<caretOffset]
    guard let slashIndex = blockPrefix.firstIndex(where: { !$0.isWhitespace }),
      blockPrefix[slashIndex] == "/"
    else { return nil }
    let queryStart = slashIndex + 1
    return SemanticMessageSlashCommand.Context(
      query: String(blockPrefix[queryStart...]),
      replacementRange: slashIndex..<caretOffset
    )
  }

  /// Captures the current selection, or the full authored body when no text is selected.
  func composeAssistanceTarget() -> ComposeAssistanceTarget {
    let offsets =
      selectionOffsets ?? (attributedText.characters.count, attributedText.characters.count)
    guard offsets.0 < offsets.1 else {
      return ComposeAssistanceTarget(
        insertionOffset: offsets.0,
        range: nil,
        scope: .authoredBody,
        sourceDocument: document,
        targetDocument: document
      )
    }
    let lower = attributedText.characters.index(attributedText.startIndex, offsetBy: offsets.0)
    let upper = attributedText.characters.index(attributedText.startIndex, offsetBy: offsets.1)
    return ComposeAssistanceTarget(
      insertionOffset: offsets.0,
      range: offsets.0..<offsets.1,
      scope: .selection,
      sourceDocument: document,
      targetDocument: SemanticMessageDocument(
        attributedText: AttributedString(attributedText[lower..<upper])
      )
    )
  }

  /// Captures the full authored body with an optional fixed insertion point.
  func composeAssistanceBodyTarget(insertionOffset: Int? = nil) -> ComposeAssistanceTarget {
    let currentOffset = selectionOffsets?.0 ?? attributedText.characters.count
    return ComposeAssistanceTarget(
      insertionOffset: min(
        max(insertionOffset ?? currentOffset, 0), attributedText.characters.count),
      range: nil,
      scope: .authoredBody,
      sourceDocument: document,
      targetDocument: document
    )
  }

  /// Applies accepted assistance as one undoable semantic-document mutation.
  func applyAssistanceDocument(
    _ replacement: SemanticMessageDocument,
    application: ComposeAssistanceApplication,
    target: ComposeAssistanceTarget
  ) -> Bool {
    guard document == target.sourceDocument else { return false }
    let previousDocument = document
    var updatedText = attributedText
    let replacementText = replacement.attributedText
    switch application {
    case .insert:
      guard target.insertionOffset <= updatedText.characters.count else { return false }
      let insertion = updatedText.characters.index(
        updatedText.startIndex,
        offsetBy: target.insertionOffset
      )
      updatedText.replaceSubrange(insertion..<insertion, with: replacementText)
    case .replaceTarget:
      if let range = target.range {
        guard range.lowerBound >= 0, range.upperBound <= updatedText.characters.count else {
          return false
        }
        let lower = updatedText.characters.index(
          updatedText.startIndex,
          offsetBy: range.lowerBound
        )
        let upper = updatedText.characters.index(
          updatedText.startIndex,
          offsetBy: range.upperBound
        )
        updatedText.replaceSubrange(lower..<upper, with: replacementText)
      } else {
        updatedText = replacementText
      }
    case .replaceSubject:
      return false
    }
    let updatedDocument = SemanticMessageDocument(attributedText: updatedText)
    if updatedDocument == previousDocument { return true }
    recordUndo(previousDocument)
    redoDocuments.removeAll()
    document = updatedDocument
    let selectionOffset = min(
      target.insertionOffset + replacementText.characters.count,
      updatedText.characters.count
    )
    replaceAttributedText(
      with: updatedDocument,
      selectionOffsets: (selectionOffset, selectionOffset)
    )
    return true
  }

  /// Converts one direct TextEditor mutation into the supported semantic vocabulary.
  func textDidChange() {
    if ignoredTextSnapshot == attributedText {
      ignoredTextSnapshot = nil
      return
    }
    let offsets =
      selectionOffsets ?? (attributedText.characters.count, attributedText.characters.count)
    _ = replaceUserText(
      with: attributedText,
      selectionOffsets: offsets.0..<offsets.1,
      convertsInputShortcuts: true
    )
  }

  /// Replaces text from one native editing transaction.
  ///
  /// - Returns: `true` when this edit completed an input shortcut.
  @discardableResult
  func replaceUserText(
    with replacement: AttributedString,
    selectionOffsets: Range<Int>,
    convertsInputShortcuts: Bool,
    recordsUndo: Bool = true
  ) -> Bool {
    let source = semanticDocument(for: replacement)
    var updatedDocument = source
    var updatedSelection = (selectionOffsets.lowerBound, selectionOffsets.upperBound)
    var undoDocument = document
    var convertedInputShortcut = false

    if convertsInputShortcuts,
      let conversion = inputShortcutConversion(for: replacement, source: source)
    {
      updatedDocument = conversion.converted
      undoDocument = conversion.source
      convertedInputShortcut = true
      let convertedCount = conversion.converted.attributedText.characters.count
      updatedSelection = (
        Self.mapSelectionOffset(
          selectionOffsets.lowerBound,
          oldCount: replacement.characters.count,
          newCount: convertedCount
        ),
        Self.mapSelectionOffset(
          selectionOffsets.upperBound,
          oldCount: replacement.characters.count,
          newCount: convertedCount
        )
      )
    }

    guard updatedDocument != document else {
      replaceAttributedText(with: updatedDocument, selectionOffsets: updatedSelection)
      return convertedInputShortcut
    }
    if recordsUndo { recordUndo(undoDocument) }
    redoDocuments.removeAll()
    document = updatedDocument
    replaceAttributedText(with: updatedDocument, selectionOffsets: updatedSelection)
    return convertedInputShortcut
  }

  /// Reports whether one proposed native edit completes an input shortcut.
  func completesInputShortcut(with replacement: AttributedString) -> Bool {
    let source = semanticDocument(for: replacement)
    return inputShortcutConversion(for: replacement, source: source) != nil
  }

  /// Synchronizes the native selection without adding an undo entry.
  func updateSelection(offsets: Range<Int>) {
    let lowerOffset = min(max(offsets.lowerBound, 0), attributedText.characters.count)
    let upperOffset = min(
      max(offsets.upperBound, lowerOffset),
      attributedText.characters.count
    )
    if let currentOffsets = selectionOffsets,
      currentOffsets == (lowerOffset, upperOffset)
    {
      return
    }
    let lower = attributedText.characters.index(attributedText.startIndex, offsetBy: lowerOffset)
    let upper = attributedText.characters.index(attributedText.startIndex, offsetBy: upperOffset)
    selection =
      lower == upper
      ? AttributedTextSelection(insertionPoint: lower)
      : AttributedTextSelection(range: lower..<upper)
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

  /// Replaces a live slash query with one semantic block command.
  @discardableResult
  func applySlashCommand(
    _ command: SemanticMessageBlockCommand,
    context: SemanticMessageSlashCommand.Context
  ) -> Bool {
    guard slashCommandContext == context else { return false }
    let previousDocument = document
    var updatedText = attributedText
    let lower = updatedText.characters.index(
      updatedText.startIndex,
      offsetBy: context.replacementRange.lowerBound
    )
    let upper = updatedText.characters.index(
      updatedText.startIndex,
      offsetBy: context.replacementRange.upperBound
    )
    updatedText.replaceSubrange(lower..<upper, with: AttributedString())
    var updatedDocument = semanticDocument(for: updatedText)
    let updatedPlainText = String(updatedText.characters)
    let blockIndex = updatedPlainText.prefix(context.replacementRange.lowerBound)
      .count(where: { $0 == "\n" })
    guard updatedDocument.blocks.indices.contains(blockIndex) else { return false }
    updatedDocument.blocks[blockIndex].kind = command.kind(ordinal: 1)
    recordUndo(previousDocument)
    redoDocuments.removeAll()
    document = updatedDocument
    replaceAttributedText(
      with: updatedDocument,
      selectionOffsets: (
        context.replacementRange.lowerBound,
        context.replacementRange.lowerBound
      )
    )
    return true
  }

  /// Removes a live slash query without applying a block transformation.
  @discardableResult
  func removeSlashCommandQuery(context: SemanticMessageSlashCommand.Context) -> Bool {
    guard slashCommandContext == context else { return false }
    let previousDocument = document
    var updatedText = attributedText
    let lower = updatedText.characters.index(
      updatedText.startIndex,
      offsetBy: context.replacementRange.lowerBound
    )
    let upper = updatedText.characters.index(
      updatedText.startIndex,
      offsetBy: context.replacementRange.upperBound
    )
    updatedText.replaceSubrange(lower..<upper, with: AttributedString())
    let updatedDocument = semanticDocument(for: updatedText)
    recordUndo(previousDocument)
    redoDocuments.removeAll()
    document = updatedDocument
    replaceAttributedText(
      with: updatedDocument,
      selectionOffsets: (
        context.replacementRange.lowerBound,
        context.replacementRange.lowerBound
      )
    )
    return true
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

  private func semanticDocument(for replacement: AttributedString) -> SemanticMessageDocument {
    var source = SemanticMessageDocument(attributedText: replacement)
    let oldText = String(document.attributedText.characters)
    let newText = String(replacement.characters)
    let changedRanges = Self.changedCharacterRanges(from: oldText, to: newText)
    let oldBlockRange = Self.blockRange(
      containing: changedRanges.old,
      in: oldText,
      blockCount: document.blocks.count
    )
    let newBlockRange = Self.blockRange(
      containing: changedRanges.new,
      in: newText,
      blockCount: source.blocks.count
    )

    let unchangedPrefixCount = min(oldBlockRange.lowerBound, newBlockRange.lowerBound)
    for index in 0..<unchangedPrefixCount where source.blocks[index].kind == .paragraph {
      source.blocks[index].kind = document.blocks[index].kind
    }
    if oldBlockRange.isEmpty == false, newBlockRange.isEmpty == false,
      source.blocks[newBlockRange.lowerBound].kind == .paragraph
    {
      source.blocks[newBlockRange.lowerBound].kind = document.blocks[oldBlockRange.lowerBound].kind
    }
    let unchangedSuffixCount = min(
      document.blocks.count - oldBlockRange.upperBound,
      source.blocks.count - newBlockRange.upperBound
    )
    for offset in 0..<unchangedSuffixCount {
      let oldIndex = document.blocks.count - offset - 1
      let newIndex = source.blocks.count - offset - 1
      if source.blocks[newIndex].kind == .paragraph {
        source.blocks[newIndex].kind = document.blocks[oldIndex].kind
      }
    }
    return source
  }

  private func inputShortcutConversion(
    for replacement: AttributedString,
    source: SemanticMessageDocument
  ) -> InputShortcutConversion? {
    let oldText = String(document.attributedText.characters)
    let newText = String(replacement.characters)
    let changedRanges = Self.changedCharacterRanges(from: oldText, to: newText)
    let oldBlockRange = Self.blockRange(
      containing: changedRanges.old,
      in: oldText,
      blockCount: document.blocks.count
    )
    let newBlockRange = Self.blockRange(
      containing: changedRanges.new,
      in: newText,
      blockCount: source.blocks.count
    )
    let oldConverted = document.convertingInputShortcuts(in: oldBlockRange)
    let newConverted = source.convertingInputShortcuts(in: newBlockRange)
    guard oldConverted == document, newConverted != source else { return nil }
    return InputShortcutConversion(converted: newConverted, source: source)
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

  private static func changedCharacterRanges(
    from oldText: String,
    to newText: String
  ) -> (old: Range<Int>, new: Range<Int>) {
    let oldCharacters = Array(oldText)
    let newCharacters = Array(newText)
    let sharedPrefixCount = zip(oldCharacters, newCharacters).prefix { $0 == $1 }.count
    let remainingOldCount = oldCharacters.count - sharedPrefixCount
    let remainingNewCount = newCharacters.count - sharedPrefixCount
    let sharedSuffixCount = zip(
      oldCharacters.suffix(remainingOldCount).reversed(),
      newCharacters.suffix(remainingNewCount).reversed()
    ).prefix { $0 == $1 }.count
    return (
      sharedPrefixCount..<(oldCharacters.count - sharedSuffixCount),
      sharedPrefixCount..<(newCharacters.count - sharedSuffixCount)
    )
  }

  private static func blockRange(
    containing characterRange: Range<Int>,
    in text: String,
    blockCount: Int
  ) -> Range<Int> {
    let characters = Array(text)
    let lowerOffset = min(characterRange.lowerBound, characters.count)
    let upperOffset = min(characterRange.upperBound, characters.count)
    let lowerBlock = characters.prefix(lowerOffset).count(where: { $0 == "\n" })
    let lastChangedOffset = upperOffset > lowerOffset ? upperOffset - 1 : upperOffset
    let upperBlock = characters.prefix(lastChangedOffset).count(where: { $0 == "\n" }) + 1
    let lowerBound = min(lowerBlock, blockCount)
    return lowerBound..<min(max(upperBlock, lowerBound), blockCount)
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
