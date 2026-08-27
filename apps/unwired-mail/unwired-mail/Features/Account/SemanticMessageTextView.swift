import SwiftUI
import UIKit

/// A native text-system editor backed by the semantic message document.
struct SemanticMessageTextView: UIViewRepresentable {
  /// The composer-owned dependencies used by an anchored assistance panel.
  struct ComposeAssistanceContext {
    let viewModel: MailAssistanceViewModel
    let currentSubject: () -> String
    let recipientDisplayNames: () -> [String]
    let applySubject: (String) -> Void
  }

  let editorModel: SemanticMessageEditorModel
  let composeAssistanceContext: ComposeAssistanceContext?
  @Binding var isFocused: Bool
  let focusRequest: Int
  let minimumHeight: CGFloat

  func makeCoordinator() -> SemanticMessageTextViewCoordinator {
    SemanticMessageTextViewCoordinator(parent: self)
  }

  func makeUIView(context: Context) -> SemanticMessageUITextView {
    let textView = SemanticMessageUITextView()
    textView.backgroundColor = .clear
    textView.delegate = context.coordinator
    textView.isScrollEnabled = false
    textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
    textView.textContainer.lineFragmentPadding = 0
    textView.adjustsFontForContentSizeCategory = true
    textView.allowsEditingTextAttributes = true
    textView.keyboardDismissMode = .interactive
    textView.accessibilityIdentifier = "mail-compose-body"
    textView.accessibilityLabel = "Message"
    textView.setContentCompressionResistancePriority(.required, for: .vertical)
    context.coordinator.textView = textView
    textView.didMoveToWindowAction = { [weak coordinator = context.coordinator] in
      coordinator?.focusIfNeeded()
    }
    textView.handleSlashCommandKey = { [weak coordinator = context.coordinator] key in
      coordinator?.handleSlashCommandKey(key) ?? false
    }
    textView.layoutSubviewsAction = { [weak coordinator = context.coordinator] in
      coordinator?.refreshSlashCommandOverlayAfterLayout()
    }
    context.coordinator.synchronizeTextView()
    return textView
  }

  func updateUIView(_ textView: SemanticMessageUITextView, context: Context) {
    context.coordinator.parent = self
    context.coordinator.synchronizeTextView()
    if isFocused, textView.isFirstResponder == false {
      context.coordinator.focusIfNeeded(for: focusRequest)
    }
  }

  static func dismantleUIView(
    _ textView: SemanticMessageUITextView,
    coordinator: SemanticMessageTextViewCoordinator
  ) {
    textView.didMoveToWindowAction = nil
    textView.handleSlashCommandKey = nil
    textView.layoutSubviewsAction = nil
    coordinator.dismissSlashCommandOverlay()
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize,
    uiView: SemanticMessageUITextView,
    context: Context
  ) -> CGSize? {
    guard let width = proposal.width else { return nil }
    let fittingSize = uiView.sizeThatFits(
      CGSize(width: width, height: .greatestFiniteMagnitude)
    )
    return CGSize(width: width, height: max(minimumHeight, ceil(fittingSize.height)))
  }
}
