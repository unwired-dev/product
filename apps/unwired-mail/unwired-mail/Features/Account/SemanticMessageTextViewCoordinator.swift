import SwiftUI
import UIKit

// swiftlint:disable file_length

@MainActor
final class SemanticMessageTextViewCoordinator: NSObject, UITextViewDelegate {
  var parent: SemanticMessageTextView
  weak var textView: SemanticMessageUITextView?

  private var isSynchronizing = false
  private var activeFocusRequest: Int?
  private var scheduledFocusRequest: Int?
  private var renderedDocument: SemanticMessageDocument?
  private var assistancePanelHost: UIHostingController<ComposeAssistanceSlashPanel>?
  private var assistancePanelInsertionOffset: Int?
  private var assistancePanelViewModel: MailAssistanceViewModel?
  private var dismissedSlashCommandContext: SemanticMessageSlashCommand.Context?
  private var slashCommandPresentation: SemanticMessageSlashCommand.Presentation?
  private var slashMenuDisplayLink: CADisplayLink?
  private var slashMenuHost: UIHostingController<SemanticMessageSlashCommand.Menu>?

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
      var stableFocusObservations = 0
      for attempt in 0..<10 {
        await Task.yield()
        guard parent.isFocused, parent.focusRequest == request, let textView else { return }
        if textView.window != nil {
          if textView.isFirstResponder {
            stableFocusObservations += 1
            if stableFocusObservations == 2 { return }
          } else {
            stableFocusObservations = 0
            _ = textView.becomeFirstResponder()
          }
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
    if text == "\n" || text == "\t", applySelectedSlashCommand() {
      return false
    }
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
    refreshSlashCommandMenu()
  }

  func textViewDidChangeSelection(_ textView: UITextView) {
    guard isSynchronizing == false else { return }
    parent.editorModel.updateSelection(
      offsets: SemanticMessageNativeText.characterRange(
        textView.selectedRange,
        in: textView.text
      )
    )
    refreshSlashCommandMenu()
  }

  func textViewDidBeginEditing(_ textView: UITextView) {
    activeFocusRequest = parent.focusRequest
    if parent.isFocused == false { parent.isFocused = true }
    dismissedSlashCommandContext = nil
    guard assistancePanelHost == nil else { return }
    refreshSlashCommandMenu()
  }

  func textViewDidEndEditing(_ textView: UITextView) {
    guard scheduledFocusRequest != parent.focusRequest else { return }
    if activeFocusRequest == parent.focusRequest, parent.isFocused {
      parent.isFocused = false
    }
    activeFocusRequest = nil
    dismissedSlashCommandContext = nil
    dismissSlashCommandMenu()
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
    refreshSlashCommandMenu()
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

extension SemanticMessageTextViewCoordinator {
  func handleSlashCommandKey(_ key: SemanticMessageUITextView.SlashCommandKey) -> Bool {
    switch key {
    case .apply:
      return applySelectedSlashCommand()
    case .dismiss:
      dismissedSlashCommandContext = slashCommandPresentation?.context
      dismissSlashCommandMenu()
      return true
    case .moveDown:
      moveSlashCommandSelection(by: 1)
      return true
    case .moveUp:
      moveSlashCommandSelection(by: -1)
      return true
    }
  }

  func refreshSlashCommandOverlayAfterLayout() {
    if assistancePanelHost == nil {
      refreshSlashCommandMenu()
    } else {
      refreshAssistancePanelPlacement()
    }
  }

  func dismissSlashCommandOverlay() {
    dismissSlashCommandMenu()
    dismissAssistancePanel(restoresFocus: false)
  }

  func dismissSlashCommandMenu() {
    slashCommandPresentation = nil
    textView?.isSlashCommandMenuActive = false
    if assistancePanelHost == nil {
      slashMenuDisplayLink?.invalidate()
      slashMenuDisplayLink = nil
    }
    if let slashMenuHost {
      slashMenuHost.willMove(toParent: nil)
      slashMenuHost.view.removeFromSuperview()
      slashMenuHost.removeFromParent()
    }
    slashMenuHost = nil
  }

  private func performNativeSlashCommandUndo(
    undoSelection: Int,
    redoSelection: Int,
    actionName: String
  ) {
    parent.editorModel.undo()
    parent.editorModel.updateSelection(offsets: undoSelection..<undoSelection)
    renderedDocument = nil
    synchronizeTextView()
    textView?.undoManager?.registerUndo(withTarget: self) { coordinator in
      coordinator.performNativeSlashCommandRedo(
        undoSelection: undoSelection,
        redoSelection: redoSelection,
        actionName: actionName
      )
    }
    textView?.undoManager?.setActionName(actionName)
  }

  private func performNativeSlashCommandRedo(
    undoSelection: Int,
    redoSelection: Int,
    actionName: String
  ) {
    parent.editorModel.redo()
    parent.editorModel.updateSelection(offsets: redoSelection..<redoSelection)
    renderedDocument = nil
    synchronizeTextView()
    registerNativeSlashCommandUndo(
      undoSelection: undoSelection,
      redoSelection: redoSelection,
      actionName: actionName
    )
  }

  private func registerNativeSlashCommandUndo(
    undoSelection: Int,
    redoSelection: Int,
    actionName: String
  ) {
    textView?.undoManager?.registerUndo(withTarget: self) { coordinator in
      coordinator.performNativeSlashCommandUndo(
        undoSelection: undoSelection,
        redoSelection: redoSelection,
        actionName: actionName
      )
    }
    textView?.undoManager?.setActionName(actionName)
  }

  private func applySelectedSlashCommand() -> Bool {
    guard let presentation = slashCommandPresentation,
      let selectedCommand = presentation.selectedCommand
    else { return false }
    switch selectedCommand {
    case .assistance(let command):
      return presentAssistancePanel(command, from: presentation)
    case .block(let command):
      guard parent.editorModel.applySlashCommand(command, context: presentation.context) else {
        return false
      }
    }
    dismissedSlashCommandContext = nil
    dismissSlashCommandMenu()
    isSynchronizing = true
    renderedDocument = nil
    synchronizeTextView()
    registerNativeSlashCommandUndo(
      undoSelection: presentation.context.replacementRange.upperBound,
      redoSelection: presentation.context.replacementRange.lowerBound,
      actionName: "Block Command"
    )
    isSynchronizing = false
    _ = textView?.becomeFirstResponder()
    return true
  }

  private func presentAssistancePanel(
    _ command: SemanticMessageSlashCommand.AssistanceCommand,
    from presentation: SemanticMessageSlashCommand.Presentation
  ) -> Bool {
    guard let context = parent.composeAssistanceContext,
      let textView,
      let containerViewController = containingViewController(for: textView),
      parent.editorModel.removeSlashCommandQuery(context: presentation.context)
    else { return false }
    context.viewModel.discardPreview()
    dismissedSlashCommandContext = nil
    dismissSlashCommandMenu()
    isSynchronizing = true
    renderedDocument = nil
    synchronizeTextView()
    registerNativeSlashCommandUndo(
      undoSelection: presentation.context.replacementRange.upperBound,
      redoSelection: presentation.context.replacementRange.lowerBound,
      actionName: "Assistance Command"
    )
    isSynchronizing = false

    assistancePanelInsertionOffset = presentation.context.replacementRange.lowerBound
    assistancePanelViewModel = context.viewModel
    let host = UIHostingController(
      rootView: makeAssistancePanel(command: command, context: context)
    )
    host.view.backgroundColor = .clear
    host.view.accessibilityViewIsModal = false
    containerViewController.addChild(host)
    containerViewController.view.addSubview(host.view)
    host.didMove(toParent: containerViewController)
    assistancePanelHost = host
    refreshAssistancePanelPlacement()
    containerViewController.view.bringSubviewToFront(host.view)
    startSlashMenuTracking()
    return true
  }

  private func makeAssistancePanel(
    command: SemanticMessageSlashCommand.AssistanceCommand,
    context: SemanticMessageTextView.ComposeAssistanceContext
  ) -> ComposeAssistanceSlashPanel {
    ComposeAssistanceSlashPanel(
      command: command,
      insertionOffset: assistancePanelInsertionOffset ?? 0,
      editorModel: parent.editorModel,
      assistanceViewModel: context.viewModel,
      currentSubject: context.currentSubject,
      recipientDisplayNames: context.recipientDisplayNames,
      applySubject: context.applySubject,
      dismiss: { [weak self] in self?.dismissAssistancePanel() }
    )
  }

  private func dismissAssistancePanel(restoresFocus: Bool = true) {
    guard assistancePanelHost != nil else { return }
    assistancePanelViewModel?.discardPreview()
    assistancePanelViewModel = nil
    assistancePanelInsertionOffset = nil
    if let assistancePanelHost {
      assistancePanelHost.willMove(toParent: nil)
      assistancePanelHost.view.removeFromSuperview()
      assistancePanelHost.removeFromParent()
    }
    assistancePanelHost = nil
    if slashMenuHost == nil {
      slashMenuDisplayLink?.invalidate()
      slashMenuDisplayLink = nil
    }
    renderedDocument = nil
    synchronizeTextView()
    if restoresFocus { _ = textView?.becomeFirstResponder() }
  }

  private func refreshAssistancePanelPlacement() {
    guard let textView,
      let assistancePanelHost,
      let insertionOffset = assistancePanelInsertionOffset,
      let containerViewController = assistancePanelHost.parent,
      let window = textView.window,
      let visibleBounds = visibleBounds(
        for: textView,
        in: containerViewController.view,
        window: window
      )
    else { return }
    let documentLength = textView.offset(
      from: textView.beginningOfDocument,
      to: textView.endOfDocument
    )
    let clampedOffset = min(max(insertionOffset, 0), documentLength)
    guard
      let anchorPosition = textView.position(
        from: textView.beginningOfDocument,
        offset: clampedOffset
      )
    else { return }
    let caretRect = textView.convert(
      textView.caretRect(for: anchorPosition),
      to: containerViewController.view
    )
    assistancePanelHost.view.frame = SemanticMessageSlashCommand.Presentation.panelFrame(
      caretRect: caretRect,
      visibleBounds: visibleBounds,
      isCompactWidth: textView.traitCollection.horizontalSizeClass == .compact
    )
  }

  private func moveSlashCommandSelection(by offset: Int) {
    guard var presentation = slashCommandPresentation else { return }
    presentation.moveSelection(by: offset)
    slashCommandPresentation = presentation
    updateSlashMenuHost(with: presentation)
  }

  private func refreshSlashCommandMenu() {
    guard assistancePanelHost == nil,
      isSynchronizing == false,
      let textView,
      textView.isFirstResponder,
      textView.markedTextRange == nil,
      let context = parent.editorModel.slashCommandContext
    else {
      dismissedSlashCommandContext = nil
      dismissSlashCommandMenu()
      return
    }
    guard context != dismissedSlashCommandContext else {
      dismissSlashCommandMenu()
      return
    }
    dismissedSlashCommandContext = nil
    guard
      let selectedTextRange = textView.selectedTextRange,
      let containerViewController = containingViewController(for: textView),
      let window = textView.window,
      let visibleBounds = visibleBounds(
        for: textView,
        in: containerViewController.view,
        window: window
      )
    else {
      dismissSlashCommandMenu()
      return
    }
    let caretRect = textView.convert(
      textView.caretRect(for: selectedTextRange.start),
      to: containerViewController.view
    )
    guard visibleBounds.intersects(caretRect) else {
      dismissSlashCommandMenu()
      return
    }
    let presentation = SemanticMessageSlashCommand.Presentation(
      context: context,
      caretRect: caretRect,
      visibleBounds: visibleBounds,
      isCompactWidth: textView.traitCollection.horizontalSizeClass == .compact,
      includesAssistance: parent.composeAssistanceContext != nil,
      selectedCommand: slashCommandPresentation?.selectedCommand
    )
    guard presentation != slashCommandPresentation else { return }
    slashCommandPresentation = presentation
    textView.isSlashCommandMenuActive = true
    updateSlashMenuHost(with: presentation, parent: containerViewController)
    startSlashMenuTracking()
  }

  private func updateSlashMenuHost(
    with presentation: SemanticMessageSlashCommand.Presentation,
    parent: UIViewController? = nil
  ) {
    let menu = SemanticMessageSlashCommand.Menu(
      presentation: presentation,
      select: { [weak self] command in
        guard let self else { return }
        slashCommandPresentation?.selectedCommand = command
        _ = applySelectedSlashCommand()
      }
    )
    if let slashMenuHost {
      slashMenuHost.rootView = menu
      slashMenuHost.view.frame = presentation.frame
      slashMenuHost.parent?.view.bringSubviewToFront(slashMenuHost.view)
      return
    }
    guard let parent else { return }
    let host = UIHostingController(rootView: menu)
    host.view.backgroundColor = .clear
    host.view.frame = presentation.frame
    host.view.accessibilityViewIsModal = false
    parent.addChild(host)
    parent.view.addSubview(host.view)
    host.didMove(toParent: parent)
    slashMenuHost = host
  }

  private func startSlashMenuTracking() {
    guard slashMenuDisplayLink == nil else { return }
    let displayLink = CADisplayLink(target: self, selector: #selector(trackSlashMenuPlacement))
    displayLink.preferredFramesPerSecond = 30
    displayLink.add(to: .main, forMode: .common)
    slashMenuDisplayLink = displayLink
  }

  @objc
  private func trackSlashMenuPlacement() {
    if assistancePanelHost == nil {
      refreshSlashCommandMenu()
    } else {
      refreshAssistancePanelPlacement()
    }
  }

  private func containingViewController(for view: UIView) -> UIViewController? {
    var responder: UIResponder? = view
    while let nextResponder = responder?.next {
      if let viewController = nextResponder as? UIViewController { return viewController }
      responder = nextResponder
    }
    return nil
  }

  private func visibleBounds(
    for textView: UIView,
    in containerView: UIView,
    window: UIWindow
  ) -> CGRect? {
    var visibleWindowBounds = window.bounds.inset(by: window.safeAreaInsets)
    let keyboardFrame = window.keyboardLayoutGuide.layoutFrame
    if keyboardFrame.minY > visibleWindowBounds.minY,
      keyboardFrame.minY < visibleWindowBounds.maxY
    {
      visibleWindowBounds.size.height = keyboardFrame.minY - visibleWindowBounds.minY
    }
    var visibleBounds = window.convert(visibleWindowBounds, to: containerView)
      .intersection(textView.convert(textView.bounds, to: containerView))
    var ancestor = textView.superview
    while let view = ancestor, view !== containerView {
      if view.clipsToBounds || view is UIScrollView {
        visibleBounds = visibleBounds.intersection(view.convert(view.bounds, to: containerView))
      }
      ancestor = view.superview
    }
    guard visibleBounds.isNull == false, visibleBounds.isEmpty == false else { return nil }
    return visibleBounds
  }
}
