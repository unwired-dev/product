import SwiftUI

// swiftlint:disable type_body_length
/// The slash-command picker opened from a query in the semantic editor.
enum SemanticMessageSlashCommand {
  /// One block or explicit Compose Assistance command in the slash catalog.
  enum Command: Equatable, Identifiable {
    case assistance(AssistanceCommand)
    case block(SemanticMessageBlockCommand)

    var id: String {
      switch self {
      case .assistance(let command): "assistance-\(command.rawValue)"
      case .block(let command): "block-\(command.rawValue)"
      }
    }

    var title: String {
      switch self {
      case .assistance(let command): command.title
      case .block(let command): command.slashTitle
      }
    }

    var systemImage: String {
      switch self {
      case .assistance(let command): command.systemImage
      case .block(let command): command.systemImage
      }
    }

    fileprivate var accessibilityIdentifier: String {
      switch self {
      case .assistance(let command): command.rawValue
      case .block(let command): command.rawValue
      }
    }

    fileprivate var searchText: String {
      switch self {
      case .assistance(let command): command.searchText
      case .block(let command): command.slashSearchText
      }
    }
  }

  /// The explicit Compose Assistance actions exposed by the slash catalog.
  enum AssistanceCommand: String, CaseIterable, Identifiable {
    case ask
    case draftFromPrompt
    case rewriteSelection
    case proofread
    case shorten
    case changeTone
    case suggestSubject

    var id: String { rawValue }

    var title: String {
      switch self {
      case .ask: "Ask Compose Assistance"
      case .changeTone: "Change Tone"
      case .draftFromPrompt: "Draft from Prompt"
      case .proofread: "Proofread"
      case .rewriteSelection: "Rewrite Selection"
      case .shorten: "Shorten"
      case .suggestSubject: "Suggest Subject"
      }
    }

    var systemImage: String {
      switch self {
      case .ask: "sparkles"
      case .changeTone: "waveform"
      case .draftFromPrompt: "text.badge.plus"
      case .proofread: "checkmark.circle"
      case .rewriteSelection: "pencil.and.scribble"
      case .shorten: "arrow.down.right.and.arrow.up.left"
      case .suggestSubject: "textformat"
      }
    }

    var requiresSelection: Bool {
      switch self {
      case .changeTone, .proofread, .rewriteSelection, .shorten: true
      case .ask, .draftFromPrompt, .suggestSubject: false
      }
    }

    var requiresInstruction: Bool {
      self == .ask || self == .draftFromPrompt || self == .rewriteSelection
    }

    /// Creates the explicit assistance action chosen by Generate.
    func makeAction(
      instruction: String,
      tone: ComposeAssistancePreset
    ) -> ComposeAssistanceAction {
      switch self {
      case .ask, .rewriteSelection: .refine(instruction: instruction)
      case .changeTone: .transform(tone)
      case .draftFromPrompt: .generateBody(prompt: instruction)
      case .proofread: .proofread
      case .shorten: .transform(.shorten)
      case .suggestSubject: .suggestSubject
      }
    }

    fileprivate var searchText: String {
      switch self {
      case .ask: "Ask Compose Assistance Help AI"
      case .changeTone: "Change Tone Professional Friendly Direct Empathetic Neutral"
      case .draftFromPrompt: "Draft from Prompt Generate Body"
      case .proofread: "Proofread Spelling Grammar"
      case .rewriteSelection: "Rewrite Selection Refine"
      case .shorten: "Shorten Concise"
      case .suggestSubject: "Suggest Subject"
      }
    }
  }

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
    var selectedCommand: Command?

    /// Creates a presentation anchored to the current caret.
    init(
      context: Context,
      caretRect: CGRect,
      visibleBounds: CGRect,
      isCompactWidth: Bool,
      includesAssistance: Bool,
      selectedCommand: Command? = nil
    ) {
      self.context = context
      self.includesAssistance = includesAssistance
      let commands = Self.commands(
        matching: context.query,
        includesAssistance: includesAssistance
      )
      self.selectedCommand =
        selectedCommand.flatMap { commands.contains($0) ? $0 : nil } ?? commands.first
      frame = Self.menuFrame(
        caretRect: caretRect,
        visibleBounds: visibleBounds,
        isCompactWidth: isCompactWidth,
        commandCount: commands.count
      )
    }

    var commands: [Command] {
      Self.commands(matching: context.query, includesAssistance: includesAssistance)
    }

    let includesAssistance: Bool

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
    static func commands(
      matching query: String,
      includesAssistance: Bool = false
    ) -> [Command] {
      let query = query.trimmingCharacters(in: .whitespaces)
      let catalog = slashCatalog(includesAssistance: includesAssistance)
      guard !query.isEmpty else { return catalog }
      return catalog.filter { $0.searchText.localizedStandardContains(query) }
    }

    /// Places the menu inside the visible editor region, preferring below the caret.
    static func menuFrame(
      caretRect: CGRect,
      visibleBounds: CGRect,
      isCompactWidth: Bool,
      commandCount: Int
    ) -> CGRect {
      let desiredHeight =
        rowHeight * CGFloat(max(1, min(commandCount, maximumVisibleRows)))
      return anchoredFrame(
        caretRect: caretRect,
        visibleBounds: visibleBounds,
        isCompactWidth: isCompactWidth,
        desiredHeight: desiredHeight
      )
    }

    /// Places an assistance panel inside the visible editor region.
    static func panelFrame(
      caretRect: CGRect,
      visibleBounds: CGRect,
      isCompactWidth: Bool
    ) -> CGRect {
      anchoredFrame(
        caretRect: caretRect,
        visibleBounds: visibleBounds,
        isCompactWidth: isCompactWidth,
        desiredHeight: 360
      )
    }

    private static func anchoredFrame(
      caretRect: CGRect,
      visibleBounds: CGRect,
      isCompactWidth: Bool,
      desiredHeight: CGFloat
    ) -> CGRect {
      let margin: CGFloat = 8
      let availableWidth = max(0, visibleBounds.width - margin * 2)
      let width =
        isCompactWidth || availableWidth < regularWidth
        ? min(regularWidth, availableWidth)
        : regularWidth
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

    private static func slashCatalog(includesAssistance: Bool) -> [Command] {
      let blocks: [Command] = [
        .block(.paragraph),
        .block(.heading1),
        .block(.heading2),
        .block(.heading3),
        .block(.bulletedList),
        .block(.numberedList),
        .block(.blockquote),
        .block(.codeBlock),
      ]
      guard includesAssistance else { return blocks }
      return blocks + AssistanceCommand.allCases.map(Command.assistance)
    }
  }

  /// The pointer-, touch-, and keyboard-readable command list.
  struct Menu: View {
    let presentation: Presentation
    let select: (Command) -> Void
    @State private var scrollPosition = ScrollPosition(idType: String.self)

    var body: some View {
      ScrollView {
        LazyVStack(spacing: 0) {
          if presentation.commands.isEmpty {
            Text("No matching commands")
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, minHeight: Presentation.rowHeight)
              .padding(.horizontal, 16)
          } else {
            ForEach(presentation.commands) { command in
              Button(
                action: { select(command) },
                label: {
                  HStack(spacing: 12) {
                    Label(command.title, systemImage: command.systemImage)
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
              .accessibilityIdentifier(
                "mail-compose-slash-command-\(command.accessibilityIdentifier)"
              )
              .id(command.id)
            }
          }
        }
        .scrollTargetLayout()
      }
      .scrollPosition($scrollPosition)
      .scrollIndicators(.visible)
      .accessibilityIdentifier("mail-compose-slash-menu-scroll")
      .onAppear(perform: scrollToSelection)
      .onChange(of: presentation.selectedCommand) { _, _ in scrollToSelection() }
      .background(.regularMaterial)
      .clipShape(.rect(cornerRadius: 12))
      .shadow(radius: 8, y: 4)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Slash commands")
      .accessibilityIdentifier("mail-compose-slash-menu")
    }

    private func scrollToSelection() {
      guard let selectedCommand = presentation.selectedCommand else { return }
      scrollPosition.scrollTo(id: selectedCommand.id, anchor: .center)
    }
  }
}
// swiftlint:enable type_body_length

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
