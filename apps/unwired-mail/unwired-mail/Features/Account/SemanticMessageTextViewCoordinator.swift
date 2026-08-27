import UIKit

@MainActor
final class SemanticMessageTextViewCoordinator: NSObject, UITextViewDelegate {
  var parent: SemanticMessageTextView
  weak var textView: SemanticMessageUITextView?

  private var isSynchronizing = false
  private var activeFocusRequest: Int?
  private var scheduledFocusRequest: Int?
  private var renderedDocument: SemanticMessageDocument?

  init(parent: SemanticMessageTextView) {
    self.parent = parent
  }

  func focusIfNeeded() {
    focusIfNeeded(for: parent.focusRequest)
  }

  func focusIfNeeded(for request: Int) {
    guard parent.isFocused, scheduledFocusRequest != request else { return }
    scheduledFocusRequest = request
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if scheduledFocusRequest == request { scheduledFocusRequest = nil }
      }
      for attempt in 0..<10 {
        await Task.yield()
        guard parent.isFocused, parent.focusRequest == request, let textView else { return }
        if textView.window != nil {
          _ = textView.becomeFirstResponder()
          if textView.isFirstResponder { return }
        }
        if attempt < 9 {
          try? await Task.sleep(for: .milliseconds(50))
        }
      }
    }
  }

  func textView(
    _ textView: UITextView,
    shouldChangeTextIn range: NSRange,
    replacementText text: String
  ) -> Bool {
    guard let semanticTextView = textView as? SemanticMessageUITextView,
      semanticTextView.isPasting == false,
      textView.markedTextRange == nil,
      let proposal = proposedText(in: textView, replacing: range, with: text)
    else { return true }
    guard parent.editorModel.completesInputShortcut(with: proposal.text) else {
      return true
    }

    isSynchronizing = true
    parent.editorModel.replaceUserText(
      with: proposal.text,
      selectionOffsets: proposal.selection,
      convertsInputShortcuts: true
    )
    renderedDocument = nil
    synchronizeTextView()
    registerNativeShortcutUndo()
    isSynchronizing = false
    return false
  }

  func textViewDidChange(_ textView: UITextView) {
    guard isSynchronizing == false else { return }
    let attributedText = SemanticMessageNativeText.semanticText(from: textView.attributedText)
    let selection = SemanticMessageNativeText.characterRange(
      textView.selectedRange,
      in: textView.text
    )
    parent.editorModel.replaceUserText(
      with: attributedText,
      selectionOffsets: selection,
      convertsInputShortcuts: false,
      recordsUndo: false
    )
    renderedDocument = parent.editorModel.document
    textView.invalidateIntrinsicContentSize()
  }

  func textViewDidChangeSelection(_ textView: UITextView) {
    guard isSynchronizing == false else { return }
    parent.editorModel.updateSelection(
      offsets: SemanticMessageNativeText.characterRange(
        textView.selectedRange,
        in: textView.text
      )
    )
  }

  func textViewDidBeginEditing(_ textView: UITextView) {
    activeFocusRequest = parent.focusRequest
    if parent.isFocused == false { parent.isFocused = true }
  }

  func textViewDidEndEditing(_ textView: UITextView) {
    if activeFocusRequest == parent.focusRequest, parent.isFocused {
      parent.isFocused = false
    }
    activeFocusRequest = nil
  }

  func synchronizeTextView() {
    guard let textView, renderedDocument != parent.editorModel.document else { return }
    let selection = SemanticMessageNativeText.nativeSelection(
      parent.editorModel.selection,
      in: parent.editorModel.attributedText
    )
    isSynchronizing = true
    textView.semanticBlockKinds = parent.editorModel.document.blocks.map(\.kind)
    textView.attributedText = SemanticMessageNativeText.renderedText(
      for: parent.editorModel.document
    )
    textView.selectedRange = selection
    textView.typingAttributes = SemanticMessageNativeText.typingAttributes(
      for: parent.editorModel.document,
      selection: selection,
      text: textView.text
    )
    textView.invalidateIntrinsicContentSize()
    textView.setNeedsDisplay()
    renderedDocument = parent.editorModel.document
    isSynchronizing = false
  }

  private func performNativeShortcutUndo() {
    parent.editorModel.undo()
    renderedDocument = nil
    synchronizeTextView()
    textView?.undoManager?.registerUndo(withTarget: self) { coordinator in
      coordinator.performNativeShortcutRedo()
    }
  }

  private func performNativeShortcutRedo() {
    parent.editorModel.redo()
    renderedDocument = nil
    synchronizeTextView()
    registerNativeShortcutUndo()
  }

  private func registerNativeShortcutUndo() {
    textView?.undoManager?.registerUndo(withTarget: self) { coordinator in
      coordinator.performNativeShortcutUndo()
    }
    textView?.undoManager?.setActionName("Input Shortcut")
  }

  private func proposedText(
    in textView: UITextView,
    replacing range: NSRange,
    with replacement: String
  ) -> (text: AttributedString, selection: Range<Int>)? {
    let updated = NSMutableAttributedString(attributedString: textView.attributedText)
    guard range.location <= updated.length, NSMaxRange(range) <= updated.length else {
      return nil
    }
    updated.replaceCharacters(in: range, with: replacement)
    let caret = range.location + (replacement as NSString).length
    return (
      SemanticMessageNativeText.semanticText(from: updated),
      SemanticMessageNativeText.characterRange(
        NSRange(location: caret, length: 0),
        in: updated.string
      )
    )
  }
}
