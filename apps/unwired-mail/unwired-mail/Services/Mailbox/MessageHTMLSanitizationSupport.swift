import Foundation
import SwiftSoup

extension MessageHTMLHiddenStylePatterns {
  static func isReadableHidden(_ style: String) -> Bool {
    if effectiveValue("display", in: style, where: isDisplayValue) == "none" { return true }
    let zeroDimensionPattern = #"^[+-]?(?:0+(?:\.0*)?|\.0+)(?:[a-z%]+)?$"#
    if ["font-size", "height", "width", "line-height"].contains(where: { property in
      effectiveValue(property, in: style, where: isLengthValue)?.range(
        of: zeroDimensionPattern,
        options: .regularExpression
      ) != nil
    }) {
      return true
    }
    let negativeValuePattern = #"^-(?:[1-9]\d*(?:\.\d+)?|0*\.\d*[1-9]\d*)(?:[a-z%]+)?$"#
    if effectiveValue("text-indent", in: style, where: isLengthValue)?.range(
      of: negativeValuePattern,
      options: .regularExpression
    ) != nil {
      return true
    }
    return (0..<4).contains { side in
      effectiveMarginValue(side, in: style)?.range(
        of: negativeValuePattern,
        options: .regularExpression
      ) != nil
    }
  }

  static func effectiveValue(
    _ targetProperty: String,
    in style: String,
    where isValidValue: (String) -> Bool
  ) -> String? {
    var effectiveDeclaration: (value: String, isImportant: Bool)?
    for declaration in declarations(in: style) where declaration.property == targetProperty {
      guard isValidValue(declaration.value) else { continue }
      if effectiveDeclaration?.isImportant == true, !declaration.isImportant { continue }
      effectiveDeclaration = (declaration.value, declaration.isImportant)
    }
    return effectiveDeclaration?.value
  }

  static func isVisibilityValue(_ value: String) -> Bool {
    ["visible", "hidden", "collapse"].contains(value) || isCSSWideKeyword(value)
  }

  static func isOpacityValue(_ value: String) -> Bool {
    value.range(
      of: #"^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:%)?$"#,
      options: .regularExpression
    ) != nil || isCSSWideKeyword(value)
  }

  static func isDisplayValue(_ value: String) -> Bool {
    let keywords = Set([
      "block", "contents", "flex", "flow", "flow-root", "grid", "inline", "inline-block",
      "inline-flex", "inline-grid", "inline-table", "list-item", "none", "ruby",
      "ruby-base", "ruby-base-container", "ruby-text", "ruby-text-container", "run-in",
      "table", "table-caption", "table-cell", "table-column", "table-column-group",
      "table-footer-group", "table-header-group", "table-row", "table-row-group",
    ])
    return isCSSWideKeyword(value)
      || value.split(whereSeparator: \Character.isWhitespace).allSatisfy {
        keywords.contains(String($0))
      }
  }

  static func isLengthValue(_ value: String) -> Bool {
    value.range(
      of: #"^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[a-z%]+)?$"#,
      options: .regularExpression
    ) != nil
      || ["auto", "fit-content", "max-content", "min-content", "normal"].contains(value)
      || isCSSWideKeyword(value)
      || value.range(
        of: #"^(?:calc|clamp|env|fit-content|max|min|var)\(.+\)$"#,
        options: .regularExpression
      ) != nil
  }

  private static func effectiveMarginValue(_ side: Int, in style: String) -> String? {
    let sideProperty = ["margin-top", "margin-right", "margin-bottom", "margin-left"][side]
    var effectiveDeclaration: (value: String, isImportant: Bool)?
    for declaration in declarations(in: style) {
      let value: String?
      if declaration.property == sideProperty {
        value = isLengthValue(declaration.value) ? declaration.value : nil
      } else if declaration.property == "margin" {
        value = marginValues(declaration.value)?[side]
      } else {
        continue
      }
      guard let value else { continue }
      if effectiveDeclaration?.isImportant == true, !declaration.isImportant { continue }
      effectiveDeclaration = (value, declaration.isImportant)
    }
    return effectiveDeclaration?.value
  }

  private static func marginValues(_ value: String) -> [String]? {
    let values = value.split(whereSeparator: \Character.isWhitespace).map(String.init)
    guard (1...4).contains(values.count), values.allSatisfy(isMarginValue) else { return nil }
    switch values.count {
    case 1: return [values[0], values[0], values[0], values[0]]
    case 2: return [values[0], values[1], values[0], values[1]]
    case 3: return [values[0], values[1], values[2], values[1]]
    default: return values
    }
  }

  private static func isMarginValue(_ value: String) -> Bool {
    value == "auto" || isLengthValue(value)
  }

  private static func isCSSWideKeyword(_ value: String) -> Bool {
    ["inherit", "initial", "revert", "revert-layer", "unset"].contains(value)
  }

  private static func declarations(in style: String) -> [StyleDeclaration] {
    style.split(separator: ";").compactMap { declaration in
      let components = declaration.split(separator: ":", maxSplits: 1)
      guard components.count == 2 else { return nil }
      let property = components[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      var value = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
      let importantRange = value.range(
        of: #"\s*!important\s*$"#,
        options: [.regularExpression, .caseInsensitive]
      )
      if let importantRange {
        value.removeSubrange(importantRange)
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      guard !property.isEmpty, !value.isEmpty else { return nil }
      return StyleDeclaration(
        property: property,
        value: value.lowercased(),
        isImportant: importantRange != nil
      )
    }
  }

  private struct StyleDeclaration {
    let property: String
    let value: String
    let isImportant: Bool
  }
}

extension MessageHTMLSanitizer {
  static func removePreCleanHiddenElements(from document: Document) throws {
    for element in try document.select("[style]")
    where MessageHTMLHiddenStylePatterns.isPreCleanHidden(try element.attr("style")) {
      try element.remove()
    }
  }

  static func sourceContent(
    in document: Document,
    cancellationCheck: () throws -> Void
  ) throws -> (
    hasText: Bool,
    hasExplicitlyHiddenText: Bool
  ) {
    try withoutActuallyEscaping(cancellationCheck) { cancellationCheck in
      let visitor = SourceContentVisitor(cancellationCheck: cancellationCheck)
      try NodeTraversor(visitor).traverse(document)
      return (visitor.hasText, visitor.hasExplicitlyHiddenText)
    }
  }

  static func hasReadableText(_ text: String) -> Bool {
    let ignoredReadableScalars =
      CharacterSet.whitespacesAndNewlines
      .union(.controlCharacters)
      .union(.nonBaseCharacters)
    return text.unicodeScalars.contains { scalar in
      !ignoredReadableScalars.contains(scalar)
        && scalar.properties.generalCategory != .format
    }
  }
}

private final class SourceContentVisitor: NodeVisitor {
  private let cancellationCheck: () throws -> Void
  private var hiddenByDepth: [Bool] = []
  private var visitedNodeCount = 0
  var hasText = false
  var hasExplicitlyHiddenText = false

  init(cancellationCheck: @escaping () throws -> Void) {
    self.cancellationCheck = cancellationCheck
  }

  func head(_ node: Node, _ depth: Int) throws {
    if visitedNodeCount.isMultiple(of: 256) { try cancellationCheck() }
    visitedNodeCount += 1

    let parentIsHidden = depth > 0 && hiddenByDepth[depth - 1]
    if let element = node as? Element {
      if hiddenByDepth.count > depth {
        hiddenByDepth.removeSubrange(depth...)
      }
      let style = try element.attr("style")
      let isHidden =
        parentIsHidden
        || element.hasAttr("hidden")
        || MessageHTMLHiddenStylePatterns.isPreCleanHidden(style)
        || MessageHTMLHiddenStylePatterns.isReadableHidden(style)
      hiddenByDepth.append(isHidden)
    } else if let textNode = node as? TextNode,
      MessageHTMLSanitizer.hasReadableText(textNode.getWholeText())
    {
      hasText = true
      hasExplicitlyHiddenText = hasExplicitlyHiddenText || parentIsHidden
    }
  }

  func tail(_: Node, _: Int) throws {}
}
