import SwiftUI

struct MailShellThreadColumnBoundsPreferenceKey: PreferenceKey {
  static let defaultValue: Anchor<CGRect>? = nil

  static func reduce(
    value: inout Anchor<CGRect>?,
    nextValue: () -> Anchor<CGRect>?
  ) {
    value = nextValue() ?? value
  }
}

struct MailShellDetailColumnBoundsPreferenceKey: PreferenceKey {
  static let defaultValue: Anchor<CGRect>? = nil

  static func reduce(
    value: inout Anchor<CGRect>?,
    nextValue: () -> Anchor<CGRect>?
  ) {
    value = nextValue() ?? value
  }
}

enum MailShellComposerPresentationMode: Equatable {
  case compactDestination
  case detailOverlay
  case expanded
}

struct MailShellComposerPresentationLayout: Equatable {
  static let collapsedHeightFraction = 0.7
  static let maximumCollapsedHeight: CGFloat = 720
  static let minimumCollapsedHeight: CGFloat = 420
  static let outerInset: CGFloat = 12

  let frame: CGRect
  let mode: MailShellComposerPresentationMode

  init(
    containerFrame: CGRect,
    detailColumnFrame: CGRect?,
    isCompact: Bool,
    isExpanded: Bool
  ) {
    if isCompact {
      frame = containerFrame
      mode = .compactDestination
      return
    }
    if isExpanded {
      frame = containerFrame
      mode = .expanded
      return
    }

    let detailFrame = detailColumnFrame ?? containerFrame
    let proposedHeight = detailFrame.height * Self.collapsedHeightFraction
    let clampedHeight = min(
      Self.maximumCollapsedHeight,
      max(Self.minimumCollapsedHeight, proposedHeight)
    )
    let availableHeight = max(0, detailFrame.height - (Self.outerInset * 2))
    let height = min(clampedHeight, availableHeight)
    frame = CGRect(
      x: detailFrame.minX + Self.outerInset,
      y: detailFrame.maxY - Self.outerInset - height,
      width: max(0, detailFrame.width - (Self.outerInset * 2)),
      height: height
    )
    mode = .detailOverlay
  }
}

struct MailShellComposerNavigationState {
  private(set) var draft: MailShellCompositionDraft?
  private var expandedDraftIds: Set<UUID> = []

  var isExpanded: Bool {
    draft.map { expandedDraftIds.contains($0.id) } ?? false
  }

  mutating func dismiss() {
    if let draft {
      expandedDraftIds.remove(draft.id)
    }
    draft = nil
  }

  mutating func dismissAll() {
    guard draft != nil || !expandedDraftIds.isEmpty else { return }
    draft = nil
    expandedDraftIds.removeAll()
  }

  mutating func park() {
    guard draft != nil else { return }
    draft = nil
  }

  mutating func present(_ draft: MailShellCompositionDraft) {
    self.draft = draft
  }

  mutating func updatePresentedDraft(_ draft: MailShellCompositionDraft) {
    self.draft = draft
  }

  mutating func toggleExpansion() {
    guard let draft else { return }
    if isExpanded {
      expandedDraftIds.remove(draft.id)
    } else {
      expandedDraftIds.insert(draft.id)
    }
  }
}
