import Foundation
import SwiftUI
import Testing

@testable import unwired_mail

struct SemanticMessageInputShortcutTests {
  struct BlockShortcutExpectation: CustomTestStringConvertible, Sendable {
    let kind: SemanticMessageDocument.Block.Kind
    let marker: String

    var testDescription: String { marker }
  }

  @MainActor
  @Test(
    "Typed block shortcuts are one undoable semantic edit",
    .bug(id: 554),
    arguments: [
      BlockShortcutExpectation(kind: .heading(level: 1), marker: "# "),
      BlockShortcutExpectation(kind: .heading(level: 2), marker: "## "),
      BlockShortcutExpectation(kind: .heading(level: 3), marker: "### "),
      BlockShortcutExpectation(kind: .bulletedListItem, marker: "- "),
      BlockShortcutExpectation(kind: .numberedListItem(ordinal: 1), marker: "1. "),
      BlockShortcutExpectation(kind: .blockquote, marker: "> "),
      BlockShortcutExpectation(kind: .codeBlock, marker: "```"),
    ]
  )
  func typedBlockShortcutIsAtomic(_ expectation: BlockShortcutExpectation) {
    let model = SemanticMessageEditorModel(
      document: SemanticMessageDocument(plainText: "")
    )
    let markerCount = expectation.marker.count

    let converted = model.replaceUserText(
      with: AttributedString(expectation.marker),
      selectionOffsets: markerCount..<markerCount,
      convertsInputShortcuts: true
    )

    #expect(converted)
    #expect(model.document.blocks == [.init(kind: expectation.kind, runs: [.init("")])])
    #expect(String(model.attributedText.characters) == "")

    model.undo()
    #expect(model.document == SemanticMessageDocument(plainText: expectation.marker))

    model.redo()
    #expect(model.document.blocks == [.init(kind: expectation.kind, runs: [.init("")])])
  }

  @MainActor
  @Test("Pasted Markdown remains literal", .bug(id: 554))
  func pastedMarkdownDoesNotApplyInputShortcuts() {
    let model = SemanticMessageEditorModel(
      document: SemanticMessageDocument(plainText: "")
    )

    let converted = model.replaceUserText(
      with: AttributedString("# Pasted heading"),
      selectionOffsets: 16..<16,
      convertsInputShortcuts: false
    )

    #expect(converted == false)
    #expect(model.document == SemanticMessageDocument(plainText: "# Pasted heading"))
  }

  @MainActor
  @Test("Typing after a block shortcut retains its semantics", .bug(id: 554))
  func typedContentRetainsConvertedBlockKind() {
    let model = SemanticMessageEditorModel(
      document: SemanticMessageDocument(plainText: "")
    )
    model.replaceUserText(
      with: AttributedString("# "),
      selectionOffsets: 2..<2,
      convertsInputShortcuts: true
    )

    let converted = model.replaceUserText(
      with: AttributedString("Title"),
      selectionOffsets: 5..<5,
      convertsInputShortcuts: true
    )

    #expect(converted == false)
    #expect(model.document.blocks == [.init(kind: .heading(level: 1), runs: [.init("Title")])])
  }

  @MainActor
  @Test("Native edits do not displace shortcut Undo", .bug(id: 554))
  func nativeEditsDoNotDisplaceShortcutUndo() {
    let model = SemanticMessageEditorModel(
      document: SemanticMessageDocument(plainText: "")
    )
    model.replaceUserText(
      with: AttributedString("# "),
      selectionOffsets: 2..<2,
      convertsInputShortcuts: true
    )
    model.replaceUserText(
      with: AttributedString("Title"),
      selectionOffsets: 5..<5,
      convertsInputShortcuts: false,
      recordsUndo: false
    )
    model.replaceUserText(
      with: AttributedString(""),
      selectionOffsets: 0..<0,
      convertsInputShortcuts: false,
      recordsUndo: false
    )

    model.undo()

    #expect(model.document == SemanticMessageDocument(plainText: "# "))
  }

  @MainActor
  @Test("Adding a block preserves existing semantics", .bug(id: 554))
  func addingBlockPreservesExistingSemantics() {
    let model = SemanticMessageEditorModel(
      document: SemanticMessageDocument(
        blocks: [.init(kind: .heading(level: 1), runs: [.init("Title")])]
      )
    )

    model.replaceUserText(
      with: AttributedString("Title\nBody"),
      selectionOffsets: 10..<10,
      convertsInputShortcuts: true
    )

    #expect(
      model.document.blocks == [
        .init(kind: .heading(level: 1), runs: [.init("Title")]),
        .init(kind: .paragraph, runs: [.init("Body")]),
      ]
    )
  }
}
