import SwiftUI
import UIKit

/// Transfers first-responder ownership from the composer Subject field to its message body.
@MainActor
final class SemanticMessageFocusBridge {
  private weak var textView: SemanticMessageUITextView?
  private var focusTask: Task<Void, Never>?

  /// Registers the native message editor that should receive composer focus.
  func register(_ textView: SemanticMessageUITextView) {
    self.textView = textView
  }

  /// Stops an in-flight responder transfer when another composer field takes focus.
  func cancelPendingFocus() {
    focusTask?.cancel()
    focusTask = nil
  }

  /// Transfers focus after the Subject field finishes handling Return.
  func focusBody(requestFocus: @escaping () -> Void) {
    cancelPendingFocus()
    focusTask = Task { @MainActor [weak self] in
      await Task.yield()
      guard let self, !Task.isCancelled else { return }
      requestFocus()
      _ = textView?.becomeFirstResponder()
      var stableFocusObservations = 0
      for attempt in 0..<12 {
        await Task.yield()
        guard !Task.isCancelled else { return }
        if let textView, textView.window != nil {
          if textView.isFirstResponder {
            stableFocusObservations += 1
            if stableFocusObservations == 2 {
              focusTask = nil
              return
            }
          } else {
            stableFocusObservations = 0
            _ = textView.becomeFirstResponder()
          }
        }
        if attempt < 11 {
          try? await Task.sleep(for: .milliseconds(250))
        }
      }
      focusTask = nil
      requestFocus()
    }
  }

  /// Unregisters the native message editor when SwiftUI dismantles it.
  func unregister(_ textView: SemanticMessageUITextView) {
    guard self.textView === textView else { return }
    self.textView = nil
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
  let focusBridge: SemanticMessageFocusBridge
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
    focusBridge.register(textView)
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
    focusBridge.register(textView)
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
    coordinator.parent.focusBridge.unregister(textView)
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
