import UIKit

final class SemanticMessageUITextView: UITextView {
  enum SlashCommandKey {
    case apply
    case dismiss
    case moveDown
    case moveUp
  }

  var semanticBlockKinds: [SemanticMessageDocument.Block.Kind] = []
  var didMoveToWindowAction: (() -> Void)?
  var handleSlashCommandKey: ((SlashCommandKey) -> Void)?
  var isSlashCommandMenuActive = false
  var layoutSubviewsAction: (() -> Void)?
  private(set) var isPasting = false

  override func didMoveToWindow() {
    super.didMoveToWindow()
    didMoveToWindowAction?()
  }

  override func paste(_ sender: Any?) {
    isPasting = true
    defer { isPasting = false }
    super.paste(sender)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    layoutSubviewsAction?()
  }

  override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    guard isSlashCommandMenuActive,
      let keyCode = presses.compactMap({ $0.key?.keyCode }).first,
      let command = slashCommandKey(for: keyCode)
    else {
      super.pressesBegan(presses, with: event)
      return
    }
    handleSlashCommandKey?(command)
  }

  override func draw(_ rect: CGRect) {
    super.draw(rect)
    drawBlockDecorations()
  }

  private func drawBlockDecorations() {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    var characterOffset = 0
    for (index, line) in lines.enumerated() where semanticBlockKinds.indices.contains(index) {
      guard
        let position = position(
          from: beginningOfDocument,
          offset: min(characterOffset, text.utf16.count)
        )
      else { continue }
      let caret = caretRect(for: position)
      switch semanticBlockKinds[index] {
      case .blockquote:
        UIColor.tertiaryLabel.setFill()
        UIRectFill(
          CGRect(x: textContainerInset.left + 4, y: caret.minY, width: 3, height: caret.height))
      case .bulletedListItem:
        drawMarker("•", beside: caret)
      case .numberedListItem(let ordinal):
        drawMarker("\(ordinal).", beside: caret)
      case .codeBlock, .heading, .paragraph:
        break
      }
      characterOffset += line.utf16.count + 1
    }
  }

  private func drawMarker(_ marker: String, beside caret: CGRect) {
    let attributes: [NSAttributedString.Key: Any] = [
      .font: UIFont.preferredFont(forTextStyle: .body),
      .foregroundColor: UIColor.secondaryLabel,
    ]
    let size = marker.size(withAttributes: attributes)
    marker.draw(
      at: CGPoint(
        x: textContainerInset.left + 4,
        y: caret.midY - size.height / 2
      ),
      withAttributes: attributes
    )
  }

  private func slashCommandKey(for keyCode: UIKeyboardHIDUsage) -> SlashCommandKey? {
    switch keyCode {
    case .keyboardDownArrow: .moveDown
    case .keyboardEscape: .dismiss
    case .keyboardReturnOrEnter, .keyboardTab: .apply
    case .keyboardUpArrow: .moveUp
    default: nil
    }
  }
}
