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
    #expect(object["body"] == nil)

    object["body"] = "Imported legacy body"
    object["document"] = nil
    let imported = try JSONDecoder().decode(
      MailShellCompositionDraft.self,
      from: JSONSerialization.data(withJSONObject: object)
    )
    #expect(imported.document == SemanticMessageDocument(plainText: "Imported legacy body"))

    var newerObject = object
    newerObject["body"] = nil
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
}
