import Foundation
import SwiftUI
import Testing

@testable import unwired_mail

struct SemanticMessageDocumentTests {
  @Test(.bug(id: 162))
  func inputShortcutsBecomeSemanticBlocksAndRuns() {
    let document = SemanticMessageDocument(
      plainText: """
        # Heading
        - Item
        1. Step
        > Quote
        ``` code
        **bold** _italic_ __under__ ~~strike~~ `inline` [site](https://example.com)
        """
    ).convertingInputShortcuts()

    #expect(document.blocks[0].kind == .heading(level: 1))
    #expect(document.blocks[1].kind == .bulletedListItem)
    #expect(document.blocks[2].kind == .numberedListItem(ordinal: 1))
    #expect(document.blocks[3].kind == .blockquote)
    #expect(document.blocks[4].kind == .codeBlock)
    #expect(document.blocks[5].runs.contains { $0.isBold })
    #expect(document.blocks[5].runs.contains { $0.isItalic })
    #expect(document.blocks[5].runs.contains { $0.isUnderlined })
    #expect(document.blocks[5].runs.contains { $0.isStruckThrough })
    #expect(document.blocks[5].runs.contains { $0.isCode })
    #expect(document.blocks[5].runs.contains { $0.link == "https://example.com" })
    #expect(document.plainText.contains("**") == false)
    #expect(document.plainText.contains("```") == false)
  }

  @Test("Standalone italic shortcut is converted", .bug(id: 162))
  func standaloneItalicShortcutIsDetected() {
    let document = SemanticMessageDocument(plainText: "_italic_").convertingInputShortcuts()

    #expect(document.blocks[0].runs == [.init("italic", isItalic: true)])
  }

  @Test("Empty inline shortcuts retain an editable run", .bug(id: 162))
  func emptyInlineShortcutProducesPlaceholderRun() {
    let document = SemanticMessageDocument(plainText: "****").convertingInputShortcuts()

    #expect(document.blocks[0].runs == [.init("")])
  }

  @Test("Incomplete shortcuts preserve existing rich runs", .bug(id: 162))
  func incompleteShortcutDoesNotFlattenFormatting() {
    let document = SemanticMessageDocument(
      blocks: [
        .init(runs: [.init("Hello", isBold: true), .init(" [")])
      ]
    ).convertingInputShortcuts()

    #expect(document.blocks[0].runs.first == .init("Hello", isBold: true))
    #expect(document.blocks[0].runs.dropFirst().allSatisfy { $0.isBold == false })
    #expect(document.plainText == "Hello [")
  }

  @Test(.bug(id: 162))
  func oneDocumentGeneratesEscapedHTMLAndPlainTextAlternatives() {
    let document = SemanticMessageDocument(
      blocks: [
        .init(kind: .heading(level: 2), runs: [.init("Plan & status", isBold: true)]),
        .init(kind: .bulletedListItem, runs: [.init("First <item>")]),
        .init(kind: .bulletedListItem, runs: [.init("Second")]),
        .init(
          kind: .paragraph,
          runs: [.init("Open", isUnderlined: true, link: "https://example.com?a=1&b=2")]
        ),
      ]
    )

    #expect(document.plainText == "Plan & status\n• First <item>\n• Second\nOpen")
    #expect(document.html.contains("<h2><strong>Plan &amp; status</strong></h2>"))
    #expect(document.html.contains("<ul><li>First &lt;item&gt;</li><li>Second</li></ul>"))
    #expect(
      document.html.contains(
        #"<u><a href="https://example.com?a=1&amp;b=2">Open</a></u>"#
      )
    )
  }

  @Test("Generated HTML preserves authored list ordinals", .bug(id: 162))
  func htmlPreservesNumberedListOrdinals() {
    let document = SemanticMessageDocument(
      blocks: [
        .init(kind: .numberedListItem(ordinal: 3), runs: [.init("Third")]),
        .init(kind: .numberedListItem(ordinal: 7), runs: [.init("Seventh")]),
      ]
    )

    #expect(
      document.html.contains(
        #"<ol start="3"><li value="3">Third</li><li value="7">Seventh</li></ol>"#
      )
    )
  }

  @Test(.bug(id: 162))
  func draftEncodingImportsLegacyTextButFailsClosedForNewerDocuments() throws {
    let draft = MailShellCompositionDraft(
      body: "Legacy-compatible text",
      connectionId: nil,
      recipient: "recipient@example.com",
      replyToMessage: nil,
      sourceMessage: nil,
      subject: "Subject"
    )
    let encoded = try JSONEncoder().encode(draft)
    var object = try #require(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )

    #expect(object["document"] != nil)
    #expect(object["body"] as? String == "Legacy-compatible text")

    object["body"] = "Imported legacy body"
    object["document"] = nil
    let imported = try JSONDecoder().decode(
      MailShellCompositionDraft.self,
      from: JSONSerialization.data(withJSONObject: object)
    )
    #expect(imported.document == SemanticMessageDocument(plainText: "Imported legacy body"))

    var newerObject = object
    newerObject["body"] = "Valid legacy body"
    newerObject["document"] = ["schemaVersion": 2, "blocks": []]
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(
        MailShellCompositionDraft.self,
        from: JSONSerialization.data(withJSONObject: newerObject)
      )
    }
  }

  @Test(.bug(id: 162))
  func decodingDropsUnsafeLinkSchemes() throws {
    let encoded = Data(
      #"{"schemaVersion":1,"blocks":[{"kind":{"paragraph":{}},"runs":[{"text":"Open","link":"javascript:alert(1)"}]}]}"#
        .utf8
    )

    let document = try JSONDecoder().decode(SemanticMessageDocument.self, from: encoded)

    #expect(document.blocks[0].runs[0].link == nil)
    #expect(document.html.contains("javascript:") == false)
  }

  @MainActor
  @Test(.bug(id: 162))
  func editorCommandsShareSemanticStateAndUndoHistory() {
    let model = SemanticMessageEditorModel(
      document: SemanticMessageDocument(plainText: "Hello")
    )
    model.selection = AttributedTextSelection(
      range: model.attributedText.startIndex..<model.attributedText.endIndex
    )

    model.toggleInline(.bold)
    #expect(model.document.blocks[0].runs == [.init("Hello", isBold: true)])

    model.applyBlock(.heading2)
    #expect(model.document.blocks[0].kind == .heading(level: 2))

    model.undo()
    #expect(model.document.blocks[0].kind == .paragraph)
    model.redo()
    #expect(model.document.blocks[0].kind == .heading(level: 2))
  }

  @MainActor
  @Test("Inline commands normalize mixed selections", .bug(id: 162))
  func inlineCommandAppliesOneStateAcrossSelection() {
    let model = SemanticMessageEditorModel(
      document: SemanticMessageDocument(
        blocks: [.init(runs: [.init("Bold", isBold: true), .init(" plain")])]
      )
    )
    model.selection = AttributedTextSelection(
      range: model.attributedText.startIndex..<model.attributedText.endIndex
    )

    model.toggleInline(.bold)

    #expect(model.document.blocks[0].runs.allSatisfy { $0.isBold })
  }

  @MainActor
  @Test("Shortcut conversion preserves the caret", .bug(id: 162))
  func shortcutConversionMapsSelectionOffsets() {
    let model = SemanticMessageEditorModel(
      document: SemanticMessageDocument(plainText: "First\nSecond")
    )
    model.attributedText = AttributedString("**First**\nSecond")
    let caret = model.attributedText.characters.index(
      model.attributedText.startIndex,
      offsetBy: 9
    )
    model.selection = AttributedTextSelection(insertionPoint: caret)

    model.textDidChange()

    guard
      case .insertionPoint(let mappedCaret) = model.selection.indices(
        in: model.attributedText
      )
    else {
      Issue.record("Expected an insertion-point selection")
      return
    }
    #expect(
      model.attributedText.characters.distance(
        from: model.attributedText.startIndex,
        to: mappedCaret
      ) == 5
    )
  }

  @MainActor
  @Test("Exclusive selection boundary excludes the next block", .bug(id: 162))
  func blockCommandExcludesFollowingLineAtUpperBoundary() {
    let model = SemanticMessageEditorModel(
      document: SemanticMessageDocument(plainText: "First\nSecond")
    )
    let secondLineStart = model.attributedText.characters.index(
      model.attributedText.startIndex,
      offsetBy: 6
    )
    model.selection = AttributedTextSelection(
      range: model.attributedText.startIndex..<secondLineStart
    )

    model.applyBlock(.heading1)

    #expect(model.document.blocks[0].kind == .heading(level: 1))
    #expect(model.document.blocks[1].kind == .paragraph)
  }

  @MainActor
  @Test("Transient text ahead of semantic blocks keeps a valid selection", .bug(id: 162))
  func blockCommandIgnoresSelectionOutsideAvailableBlocks() {
    let model = SemanticMessageEditorModel(
      document: SemanticMessageDocument(plainText: "First")
    )
    model.attributedText = AttributedString("First\nSecond")
    let secondLineStart = model.attributedText.characters.index(
      model.attributedText.startIndex,
      offsetBy: 6
    )
    model.selection = AttributedTextSelection(
      range: secondLineStart..<model.attributedText.endIndex
    )

    model.applyBlock(.heading1)

    #expect(model.document.blocks[0].kind == .paragraph)
    guard case .ranges(let ranges) = model.selection.indices(in: model.attributedText),
      let selectedRange = ranges.ranges.first
    else {
      Issue.record("Expected the transient text selection to remain valid")
      return
    }
    #expect(ranges.ranges.count == 1)
    #expect(selectedRange == secondLineStart..<model.attributedText.endIndex)
  }
}
