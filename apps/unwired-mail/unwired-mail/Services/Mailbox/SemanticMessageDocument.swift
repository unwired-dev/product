import Foundation

// The public shape deliberately keeps semantic blocks and runs colocated with their document.
// swiftlint:disable type_body_length nesting
/// A versioned, provider-independent representation of authored message content.
struct SemanticMessageDocument: Codable, Equatable, Sendable {
  /// One semantic block in the document.
  struct Block: Codable, Equatable, Sendable {
    /// The supported block-level presentation.
    enum Kind: Codable, Equatable, Sendable {
      case blockquote
      case bulletedListItem
      case codeBlock
      case heading(level: Int)
      case numberedListItem(ordinal: Int)
      case paragraph
    }

    var kind: Kind
    var runs: [Run]

    /// Creates a block from its presentation and inline content.
    init(kind: Kind = .paragraph, runs: [Run]) {
      self.kind = kind
      self.runs = runs
    }

    var text: String {
      runs.map(\.text).joined()
    }
  }

  /// One text run with the supported inline presentation.
  struct Run: Codable, Equatable, Sendable {
    var isBold: Bool
    var isCode: Bool
    var isItalic: Bool
    var isStruckThrough: Bool
    var isUnderlined: Bool
    var link: String?
    var text: String

    /// Creates a text run without admitting fonts, colors, sizes, or alignment.
    init(
      _ text: String,
      isBold: Bool = false,
      isCode: Bool = false,
      isItalic: Bool = false,
      isStruckThrough: Bool = false,
      isUnderlined: Bool = false,
      link: String? = nil
    ) {
      self.isBold = isBold
      self.isCode = isCode
      self.isItalic = isItalic
      self.isStruckThrough = isStruckThrough
      self.isUnderlined = isUnderlined
      self.link = Self.validatedLink(link)
      self.text = text
    }

    private enum CodingKeys: String, CodingKey {
      case isBold
      case isCode
      case isItalic
      case isStruckThrough
      case isUnderlined
      case link
      case text
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      isBold = try container.decodeIfPresent(Bool.self, forKey: .isBold) ?? false
      isCode = try container.decodeIfPresent(Bool.self, forKey: .isCode) ?? false
      isItalic = try container.decodeIfPresent(Bool.self, forKey: .isItalic) ?? false
      isStruckThrough =
        try container.decodeIfPresent(Bool.self, forKey: .isStruckThrough) ?? false
      isUnderlined = try container.decodeIfPresent(Bool.self, forKey: .isUnderlined) ?? false
      link = Self.validatedLink(try container.decodeIfPresent(String.self, forKey: .link))
      text = try container.decode(String.self, forKey: .text)
    }

    private static func validatedLink(_ value: String?) -> String? {
      guard let value,
        let components = URLComponents(string: value),
        let scheme = components.scheme?.lowercased(),
        ["http", "https", "mailto"].contains(scheme),
        scheme == "mailto" || components.host?.isEmpty == false
      else { return nil }
      return value
    }
  }

  static let supportedSchemaVersion = 1

  var blocks: [Block]
  let schemaVersion: Int

  /// Creates a semantic document from validated blocks.
  init(blocks: [Block], schemaVersion: Int = Self.supportedSchemaVersion) {
    self.blocks = blocks.isEmpty ? [Block(runs: [Run("")])] : blocks
    self.schemaVersion = schemaVersion
  }

  /// Imports legacy plain text as paragraphs without interpreting it as stored Markdown.
  init(plainText: String) {
    let lines = plainText.split(separator: "\n", omittingEmptySubsequences: false)
    self.init(blocks: lines.map { Block(runs: [Run(String($0))]) })
  }

  /// Returns a document after converting complete Markdown-style input shortcuts.
  func convertingInputShortcuts() -> SemanticMessageDocument {
    SemanticMessageDocument(
      blocks: blocks.enumerated().map { index, block in
        var converted = block
        let blockShortcut = Self.blockShortcut(in: converted.text, fallbackOrdinal: index + 1)
        if converted.kind == .paragraph, let blockShortcut {
          converted.kind = blockShortcut.kind
          converted.runs = Self.inlineRuns(in: blockShortcut.text)
        } else if Self.containsInlineShortcut(converted.text) {
          converted.runs = Self.inlineRuns(in: converted.text)
        }
        return converted
      }
    )
  }

  /// Returns the standards-compatible plain-text alternative.
  var plainText: String {
    blocks.map { block in
      switch block.kind {
      case .blockquote:
        "> \(block.text)"
      case .bulletedListItem:
        "• \(block.text)"
      case .numberedListItem(let ordinal):
        "\(ordinal). \(block.text)"
      case .codeBlock, .heading, .paragraph:
        block.text
      }
    }.joined(separator: "\n")
  }

  /// Returns conservative HTML derived from the same semantic content as `plainText`.
  var html: String {
    var result = ""
    var openList: Block.Kind?
    for block in blocks {
      let listKind: Block.Kind? =
        switch block.kind {
        case .bulletedListItem: .bulletedListItem
        case .numberedListItem: .numberedListItem(ordinal: 1)
        default: nil
        }
      if !Self.sameListKind(openList, listKind) {
        result += Self.closingListTag(for: openList)
        result += Self.openingListTag(for: listKind)
        openList = listKind
      }
      let inlineHTML = block.runs.map(Self.html(for:)).joined()
      switch block.kind {
      case .blockquote:
        result += "<blockquote>\(inlineHTML)</blockquote>"
      case .bulletedListItem, .numberedListItem:
        result += "<li>\(inlineHTML)</li>"
      case .codeBlock:
        result += "<pre><code>\(Self.escapeHTML(block.text))</code></pre>"
      case .heading(let level):
        let safeLevel = min(max(level, 1), 3)
        result += "<h\(safeLevel)>\(inlineHTML)</h\(safeLevel)>"
      case .paragraph:
        result += inlineHTML.isEmpty ? "<p><br></p>" : "<p>\(inlineHTML)</p>"
      }
    }
    result += Self.closingListTag(for: openList)
    return "<!doctype html><html><body>\(result)</body></html>"
  }

  /// Appends blocks while retaining a single supported schema version.
  mutating func append(contentsOf document: SemanticMessageDocument) {
    blocks.append(contentsOf: document.blocks)
  }

  private enum CodingKeys: String, CodingKey {
    case blocks
    case schemaVersion
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedVersion = try container.decode(Int.self, forKey: .schemaVersion)
    guard decodedVersion == Self.supportedSchemaVersion else {
      throw DecodingError.dataCorruptedError(
        forKey: .schemaVersion,
        in: container,
        debugDescription: "Semantic Message Document version is not supported."
      )
    }
    let decodedBlocks = try container.decode([Block].self, forKey: .blocks)
    for block in decodedBlocks {
      if case .heading(let level) = block.kind, !(1...3).contains(level) {
        throw DecodingError.dataCorruptedError(
          forKey: .blocks,
          in: container,
          debugDescription: "Semantic Message Document contains an unsupported heading."
        )
      }
    }
    blocks = decodedBlocks.isEmpty ? [Block(runs: [Run("")])] : decodedBlocks
    schemaVersion = decodedVersion
  }

  private static func blockShortcut(
    in text: String,
    fallbackOrdinal: Int
  ) -> (kind: Block.Kind, text: String)? {
    let shortcuts: [(String, Block.Kind)] = [
      ("### ", .heading(level: 3)),
      ("## ", .heading(level: 2)),
      ("# ", .heading(level: 1)),
      ("``` ", .codeBlock),
      ("> ", .blockquote),
      ("- ", .bulletedListItem),
      ("* ", .bulletedListItem),
    ]
    if let shortcut = shortcuts.first(where: { text.hasPrefix($0.0) }) {
      return (shortcut.1, String(text.dropFirst(shortcut.0.count)))
    }
    guard let separator = text.firstIndex(of: "."),
      text[text.index(after: separator)...].hasPrefix(" "),
      let ordinal = Int(text[..<separator]),
      ordinal > 0
    else { return nil }
    let contentStart = text.index(separator, offsetBy: 2)
    return (
      .numberedListItem(ordinal: ordinal == 0 ? fallbackOrdinal : ordinal),
      String(text[contentStart...])
    )
  }

  private static func containsInlineShortcut(_ text: String) -> Bool {
    ["**", "__", "~~", "`", "["].contains { text.contains($0) }
  }

  private static func inlineRuns(in text: String) -> [Run] {
    var runs: [Run] = []
    var remainder = text[...]
    // The tuple mirrors the concise syntax table and keeps parsing order explicit.
    // swiftlint:disable:next large_tuple
    let patterns: [(opening: String, closing: String, style: (String) -> Run)] = [
      ("**", "**", { Run($0, isBold: true) }),
      ("__", "__", { Run($0, isUnderlined: true) }),
      ("~~", "~~", { Run($0, isStruckThrough: true) }),
      ("`", "`", { Run($0, isCode: true) }),
      ("_", "_", { Run($0, isItalic: true) }),
    ]
    while !remainder.isEmpty {
      if remainder.first == "[",
        let labelEnd = remainder.firstIndex(of: "]"),
        labelEnd < remainder.endIndex,
        remainder[remainder.index(after: labelEnd)...].hasPrefix("("),
        let destinationEnd = remainder[remainder.index(labelEnd, offsetBy: 2)...].firstIndex(
          of: ")")
      {
        let label = String(remainder[remainder.index(after: remainder.startIndex)..<labelEnd])
        let destinationStart = remainder.index(labelEnd, offsetBy: 2)
        let destination = String(remainder[destinationStart..<destinationEnd])
        let linked = Run(label, link: destination)
        if linked.link != nil {
          runs.append(linked)
          remainder = remainder[remainder.index(after: destinationEnd)...]
          continue
        }
      }
      if let pattern = patterns.first(where: { remainder.hasPrefix($0.opening) }),
        let closingRange = remainder.dropFirst(pattern.opening.count).range(of: pattern.closing)
      {
        let contentStart = remainder.index(remainder.startIndex, offsetBy: pattern.opening.count)
        runs.append(pattern.style(String(remainder[contentStart..<closingRange.lowerBound])))
        remainder = remainder[closingRange.upperBound...]
        continue
      }
      let nextSpecial =
        remainder.indices.dropFirst().first { index in
          remainder[index] == "[" || patterns.contains { remainder[index...].hasPrefix($0.opening) }
        } ?? remainder.endIndex
      runs.append(Run(String(remainder[..<nextSpecial])))
      remainder = remainder[nextSpecial...]
    }
    return runs.isEmpty ? [Run("")] : runs.filter { !$0.text.isEmpty }
  }

  private static func html(for run: Run) -> String {
    var value = escapeHTML(run.text).replacingOccurrences(of: "\n", with: "<br>")
    if run.isCode { value = "<code>\(value)</code>" }
    if let link = run.link { value = "<a href=\"\(escapeHTML(link))\">\(value)</a>" }
    if run.isUnderlined { value = "<u>\(value)</u>" }
    if run.isStruckThrough { value = "<s>\(value)</s>" }
    if run.isItalic { value = "<em>\(value)</em>" }
    if run.isBold { value = "<strong>\(value)</strong>" }
    return value
  }

  private static func escapeHTML(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&#39;")
  }

  private static func sameListKind(_ lhs: Block.Kind?, _ rhs: Block.Kind?) -> Bool {
    switch (lhs, rhs) {
    case (.bulletedListItem?, .bulletedListItem?): true
    case (.numberedListItem?, .numberedListItem?): true
    case (nil, nil): true
    default: false
    }
  }

  private static func openingListTag(for kind: Block.Kind?) -> String {
    switch kind {
    case .bulletedListItem: "<ul>"
    case .numberedListItem: "<ol>"
    default: ""
    }
  }

  private static func closingListTag(for kind: Block.Kind?) -> String {
    switch kind {
    case .bulletedListItem: "</ul>"
    case .numberedListItem: "</ol>"
    default: ""
    }
  }
}
// swiftlint:enable type_body_length nesting
