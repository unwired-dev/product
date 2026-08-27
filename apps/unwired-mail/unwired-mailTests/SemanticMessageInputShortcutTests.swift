import Foundation
import SwiftUI
import Testing

@testable import unwired_mail

// swiftlint:disable:next type_body_length
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

  @MainActor
  @Test("Slash queries begin at the first authored character", .bug(id: 563))
  func slashQueryBeginsAtFirstAuthoredCharacter() {
    let model = SemanticMessageEditorModel(
      document: SemanticMessageDocument(plainText: "Intro\n  /hea")
    )

    #expect(
      model.slashCommandContext
        == SemanticMessageSlashCommand.Context(query: "hea", replacementRange: 8..<12)
    )
    #expect(
      SemanticMessageSlashCommand.Presentation.commands(matching: "hea")
        == [.block(.heading1), .block(.heading2), .block(.heading3)]
    )
  }

  @MainActor
  @Test(
    "Slashes in prose, dates, and URLs do not open block commands",
    .bug(id: 563),
    arguments: [
      "Read / later",
      "2026/08/26",
      "https://example.com",
    ]
  )
  func embeddedSlashDoesNotOpenCommands(_ text: String) {
    let model = SemanticMessageEditorModel(
      document: SemanticMessageDocument(plainText: text)
    )

    #expect(model.slashCommandContext == nil)
  }

  @MainActor
  @Test("Applying a slash command is one reversible document edit", .bug(id: 563))
  func slashCommandIsAtomic() throws {
    let source = SemanticMessageDocument(plainText: "Intro\n  /quo")
    let model = SemanticMessageEditorModel(document: source)
    let context = try #require(model.slashCommandContext)

    #expect(model.applySlashCommand(.blockquote, context: context))
    #expect(
      model.document.blocks == [
        .init(runs: [.init("Intro")]),
        .init(kind: .blockquote, runs: [.init("  ")]),
      ]
    )

    model.undo()
    #expect(model.document == source)

    model.redo()
    #expect(model.document.blocks[1].kind == .blockquote)
  }

  @MainActor
  @Test("Slash command Undo restores its query caret", .bug(id: 563))
  func slashCommandUndoRestoresQueryCaret() throws {
    let source = SemanticMessageDocument(plainText: "Intro\n/quo\nOutro")
    let model = SemanticMessageEditorModel(document: source)
    model.updateSelection(offsets: 10..<10)
    let context = try #require(model.slashCommandContext)

    #expect(model.applySlashCommand(.blockquote, context: context))
    model.undo()
    model.updateSelection(
      offsets: context.replacementRange.upperBound..<context.replacementRange.upperBound
    )

    #expect(model.document == source)
    #expect(model.slashCommandContext == context)
  }

  @Test("Slash command catalog contains only interoperable blocks", .bug(id: 563))
  func slashCommandCatalogIsBounded() {
    #expect(
      SemanticMessageSlashCommand.Presentation.commands(matching: "")
        == [
          .block(.paragraph),
          .block(.heading1),
          .block(.heading2),
          .block(.heading3),
          .block(.bulletedList),
          .block(.numberedList),
          .block(.blockquote),
          .block(.codeBlock),
        ]
    )
  }

  @Test("Slash command catalog appends every explicit assistance action", .bug(id: 564))
  func slashCommandCatalogIncludesComposeAssistance() {
    let commands = SemanticMessageSlashCommand.Presentation.commands(
      matching: "",
      includesAssistance: true
    )

    #expect(
      Array(commands.suffix(7))
        == [
          .assistance(.ask),
          .assistance(.draftFromPrompt),
          .assistance(.rewriteSelection),
          .assistance(.proofread),
          .assistance(.shorten),
          .assistance(.changeTone),
          .assistance(.suggestSubject),
        ]
    )
    #expect(
      SemanticMessageSlashCommand.Presentation.commands(
        matching: "tone",
        includesAssistance: true
      ) == [.assistance(.changeTone)]
    )
  }

  @MainActor
  @Test("Choosing assistance removes only the slash query and remains undoable", .bug(id: 564))
  func assistanceCommandConsumptionIsAtomic() throws {
    let source = SemanticMessageDocument(plainText: "Intro\n  /ask\nOutro")
    let model = SemanticMessageEditorModel(document: source)
    model.updateSelection(offsets: 12..<12)
    let context = try #require(model.slashCommandContext)

    #expect(model.removeSlashCommandQuery(context: context))
    #expect(model.document.plainText == "Intro\n  \nOutro")
    #expect(model.composeAssistanceBodyTarget().insertionOffset == 8)

    model.undo()
    #expect(model.document == source)
  }

  @Test("Slash menu clamps on compact width and flips above the caret", .bug(id: 563))
  func slashMenuUsesAdaptiveGeometry() {
    let compactFrame = SemanticMessageSlashCommand.Presentation.menuFrame(
      caretRect: CGRect(x: 250, y: 500, width: 2, height: 24),
      visibleBounds: CGRect(x: 0, y: 0, width: 280, height: 560),
      isCompactWidth: true,
      commandCount: 8
    )
    let regularFrame = SemanticMessageSlashCommand.Presentation.menuFrame(
      caretRect: CGRect(x: 500, y: 620, width: 2, height: 24),
      visibleBounds: CGRect(x: 0, y: 0, width: 700, height: 680),
      isCompactWidth: false,
      commandCount: 8
    )

    #expect(compactFrame.width == 264)
    #expect(compactFrame.maxX <= 272)
    #expect(compactFrame.height == 264)
    #expect(regularFrame.width == 320)
    #expect(regularFrame.maxY < 620)

    let panelFrame = SemanticMessageSlashCommand.Presentation.panelFrame(
      caretRect: CGRect(x: 250, y: 500, width: 2, height: 24),
      visibleBounds: CGRect(x: 0, y: 0, width: 280, height: 560),
      isCompactWidth: true
    )
    #expect(panelFrame.width == 264)
    #expect(panelFrame.height == 360)
    #expect(panelFrame.maxY < 500)
  }
}
