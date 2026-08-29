import SwiftUI
import UIKit

@MainActor
final class SemanticMessageFocusBridge {
  private weak var textView: SemanticMessageUITextView?
  private var focusTask: Task<Void, Never>?

  func register(_ textView: SemanticMessageUITextView) {
    self.textView = textView
  }

  func unregister(_ textView: SemanticMessageUITextView) {
    guard self.textView === textView else { return }
    focusTask?.cancel()
    focusTask = nil
    self.textView = nil
  }

  func focusBody(from subjectField: UITextField, fallback: @escaping () -> Void) {
    focusTask?.cancel()
    focusTask = Task { @MainActor [weak self, weak subjectField] in
      subjectField?.resignFirstResponder()
      for attempt in 0..<12 {
        await Task.yield()
        guard let self, !Task.isCancelled else { return }
        if let textView, textView.window != nil, textView.becomeFirstResponder() {
          focusTask = nil
          return
        }
        if attempt < 11 {
          try? await Task.sleep(for: .milliseconds(50))
        }
      }
      focusTask = nil
      fallback()
    }
  }
}

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
  let focusBridge: SemanticMessageFocusBridge?
  let focusRequest: Int
  let focusDidBegin: () -> Void
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
    focusBridge?.register(textView)
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
    focusBridge?.register(textView)
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
    coordinator.parent.focusBridge?.unregister(textView)
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
