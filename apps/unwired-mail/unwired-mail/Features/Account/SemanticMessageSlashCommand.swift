import SwiftUI

/// The block-command picker opened from a slash query in the semantic editor.
enum SemanticMessageSlashCommand {
  /// A live slash query and the authored range it will replace.
  struct Context: Equatable {
    let query: String
    let replacementRange: Range<Int>
  }

  /// The current command choices and their menu placement.
  struct Presentation: Equatable {
    static let maximumVisibleRows = 6
    static let regularWidth: CGFloat = 320
    static let rowHeight: CGFloat = 44

    let context: Context
    let frame: CGRect
    var selectedCommand: SemanticMessageBlockCommand?

    /// Creates a presentation anchored to the current caret.
    init(
      context: Context,
      caretRect: CGRect,
      visibleBounds: CGRect,
      isCompactWidth: Bool,
      selectedCommand: SemanticMessageBlockCommand? = nil
    ) {
      self.context = context
      let commands = Self.commands(matching: context.query)
      self.selectedCommand =
        selectedCommand.flatMap { commands.contains($0) ? $0 : nil } ?? commands.first
      frame = Self.menuFrame(
        caretRect: caretRect,
        visibleBounds: visibleBounds,
        isCompactWidth: isCompactWidth,
        commandCount: commands.count
      )
    }

    var commands: [SemanticMessageBlockCommand] {
      Self.commands(matching: context.query)
    }

    /// Moves the active command by one keyboard step, wrapping at either end.
    mutating func moveSelection(by offset: Int) {
      let commands = commands
      guard !commands.isEmpty else {
        selectedCommand = nil
        return
      }
      let currentIndex = selectedCommand.flatMap(commands.firstIndex(of:)) ?? 0
      selectedCommand = commands[(currentIndex + offset + commands.count) % commands.count]
    }

    /// Returns the supported block commands filtered by a localized user query.
    static func commands(matching query: String) -> [SemanticMessageBlockCommand] {
      let query = query.trimmingCharacters(in: .whitespaces)
      guard !query.isEmpty else { return slashCatalog }
      return slashCatalog.filter { $0.slashSearchText.localizedStandardContains(query) }
    }

    /// Places the menu inside the visible editor region, preferring below the caret.
    static func menuFrame(
      caretRect: CGRect,
      visibleBounds: CGRect,
      isCompactWidth: Bool,
      commandCount: Int
    ) -> CGRect {
      let margin: CGFloat = 8
      let availableWidth = max(0, visibleBounds.width - margin * 2)
      let width =
        isCompactWidth
        ? min(regularWidth, availableWidth)
        : regularWidth
      let desiredHeight =
        rowHeight * CGFloat(max(1, min(commandCount, maximumVisibleRows)))
      let height = min(desiredHeight, max(0, visibleBounds.height - margin * 2))
      let minimumX = visibleBounds.minX + margin
      let maximumX = max(minimumX, visibleBounds.maxX - margin - width)
      let originX = min(max(caretRect.minX, minimumX), maximumX)
      let belowSpace = visibleBounds.maxY - margin - caretRect.maxY
      let aboveSpace = caretRect.minY - visibleBounds.minY - margin
      let opensAbove = belowSpace < height && aboveSpace > belowSpace
      let preferredY = opensAbove ? caretRect.minY - margin - height : caretRect.maxY + margin
      let minimumY = visibleBounds.minY + margin
      let maximumY = max(minimumY, visibleBounds.maxY - margin - height)
      let originY = min(max(preferredY, minimumY), maximumY)
      return CGRect(x: originX, y: originY, width: width, height: height)
    }

    private static let slashCatalog: [SemanticMessageBlockCommand] = [
      .paragraph,
      .heading1,
      .heading2,
      .heading3,
      .bulletedList,
      .numberedList,
      .blockquote,
      .codeBlock,
    ]
  }

  /// The pointer-, touch-, and keyboard-readable command list.
  struct Menu: View {
    let presentation: Presentation
    let select: (SemanticMessageBlockCommand) -> Void

    var body: some View {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 0) {
            if presentation.commands.isEmpty {
              Text("No matching blocks")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: Presentation.rowHeight)
                .padding(.horizontal, 16)
            } else {
              ForEach(presentation.commands) { command in
                Button(
                  action: { select(command) },
                  label: {
                    HStack(spacing: 12) {
                      Label(command.slashTitle, systemImage: command.systemImage)
                      Spacer(minLength: 8)
                      if command == presentation.selectedCommand {
                        Image(systemName: "checkmark")
                          .accessibilityHidden(true)
                      }
                    }
                    .contentShape(.rect)
                    .padding(.horizontal, 16)
                    .frame(minHeight: Presentation.rowHeight)
                    .background(
                      command == presentation.selectedCommand
                        ? Color.accentColor.opacity(0.15) : .clear
                    )
                  }
                )
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityAddTraits(
                  command == presentation.selectedCommand ? .isSelected : []
                )
                .accessibilityIdentifier("mail-compose-slash-command-\(command.rawValue)")
                .id(command)
              }
            }
          }
        }
        .scrollIndicators(.visible)
        .accessibilityIdentifier("mail-compose-slash-menu-scroll")
        .onAppear { scrollToSelection(using: proxy) }
        .onChange(of: presentation.selectedCommand) { _, _ in
          scrollToSelection(using: proxy)
        }
      }
      .background(.regularMaterial)
      .clipShape(.rect(cornerRadius: 12))
      .shadow(radius: 8, y: 4)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Block commands")
      .accessibilityIdentifier("mail-compose-slash-menu")
    }

    private func scrollToSelection(using proxy: ScrollViewProxy) {
      guard let selectedCommand = presentation.selectedCommand else { return }
      proxy.scrollTo(selectedCommand, anchor: .center)
    }
  }
}

extension SemanticMessageBlockCommand {
  fileprivate var slashTitle: String {
    switch self {
    case .blockquote: "Quote"
    case .paragraph: "Text"
    default: title
    }
  }

  fileprivate var slashSearchText: String {
    switch self {
    case .blockquote: "Quote Blockquote"
    case .paragraph: "Text Paragraph"
    default: slashTitle
    }
  }
}
