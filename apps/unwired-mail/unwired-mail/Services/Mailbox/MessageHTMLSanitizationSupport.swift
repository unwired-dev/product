import Foundation
import SwiftSoup

enum CSSLengthValuePolicy {
  static let unitPattern = #"(?:ch|cm|em|ex|in|mm|pc|pt|px|q|rem|vh|vmax|vmin|vw|%)"#
  static let optionalUnitPattern = unitPattern + "?"
  static let unsignedZeroPattern = #"(?:0+(?:\.0*)?|\.0+)"#
  static let zeroLengthPattern = #"[+-]?"# + unsignedZeroPattern + optionalUnitPattern
}

extension MessageHTMLHiddenStylePatterns {
  static func isReadableHidden(_ declarations: [StyleDeclaration]) -> Bool {
    if effectiveValue("display", in: declarations, where: isDisplayValue) == "none" {
      return true
    }
    if ["font-size", "height", "width", "line-height"].contains(where: { property in
      effectiveValue(property, in: declarations) { value in
        isLengthValue(value, for: property)
      }.map(isZeroLengthValue) == true
    }) {
      return true
    }
    return isOffCanvasHidden(declarations)
  }

  static func effectiveValue(
    _ targetProperty: String,
    in declarations: [StyleDeclaration],
    where isValidValue: (String) -> Bool
  ) -> String? {
    var effectiveDeclaration: (value: String, isImportant: Bool)?
    for declaration in declarations where declaration.property == targetProperty {
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
    ) != nil || simpleCalculatedOpacity(value) != nil || isCSSWideKeyword(value)
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

  static func isLengthValue(_ value: String, for property: String) -> Bool {
    if value.range(
      of: #"^[+-]?(?:\d+(?:\.\d*)?|\.\d+)"#
        + CSSLengthValuePolicy.optionalUnitPattern + "$",
      options: .regularExpression
    ) != nil {
      let isUnitlessNonzero =
        value.range(
          of: #"^[+-]?(?:(?:[1-9]\d*)(?:\.\d*)?|0*\.\d*[1-9]\d*)$"#,
          options: .regularExpression
        ) != nil
      return property == "line-height" || !isUnitlessNonzero
    }
    if value == "normal" { return property == "line-height" }
    return ["auto", "fit-content", "max-content", "min-content", "none"].contains(value)
      || isCSSWideKeyword(value)
      || isCSSFunctionValue(value)
  }

  static func isZeroLengthValue(_ value: String) -> Bool {
    value.range(
      of: "^" + CSSLengthValuePolicy.zeroLengthPattern + "$",
      options: .regularExpression
    ) != nil
      || isCalculatedZeroLengthValue(value)
      || simpleCalculatedPixelLengthValue(value).map { abs($0) < 0.000_000_001 } == true
  }

  static func isOnePixelLengthValue(_ value: String) -> Bool {
    let onePixelPattern = #"\+?0*1(?:\.0*)?px"#
    if value.range(
      of: "^" + onePixelPattern + "$",
      options: [.regularExpression, .caseInsensitive]
    ) != nil {
      return true
    }
    return simpleCalculatedPixelLengthValue(value).map {
      abs($0 - 1) < 0.000_000_001
    } == true
  }

  // swiftlint:disable:next cyclomatic_complexity
  static func simpleCalculatedPixelLengthValue(_ value: String) -> Double? {
    let normalized = value.lowercased()
    guard normalized.hasPrefix("calc("), normalized.hasSuffix(")") else { return nil }
    let expression = Array(normalized.dropFirst(5).dropLast().filter { !$0.isWhitespace })
    guard !expression.isEmpty else { return nil }
    var index = 0
    var termCount = 0
    var total = 0.0
    while index < expression.count {
      var sign = 1.0
      if expression[index] == "+" || expression[index] == "-" {
        sign = expression[index] == "-" ? -1 : 1
        index += 1
      } else if termCount > 0 {
        return nil
      }
      let numberStart = index
      var hasDigit = false
      var hasDecimalPoint = false
      while index < expression.count {
        if expression[index].isNumber {
          hasDigit = true
        } else if expression[index] == ".", !hasDecimalPoint {
          hasDecimalPoint = true
        } else {
          break
        }
        index += 1
      }
      guard hasDigit,
        let number = Double(String(expression[numberStart..<index]))
      else { return nil }
      let unitStart = index
      while index < expression.count,
        expression[index].isLetter || expression[index] == "%"
      {
        index += 1
      }
      let unit = String(expression[unitStart..<index])
      let zeroLengthUnits = Set([
        "", "%", "ch", "cm", "em", "ex", "in", "mm", "pc", "pt", "px", "q", "rem", "vh",
        "vmax", "vmin", "vw",
      ])
      guard unit == "px" || (number == 0 && zeroLengthUnits.contains(unit)) else { return nil }
      if unit == "px" { total += sign * number }
      termCount += 1
    }
    return total
  }

  private static func isCalculatedZeroLengthValue(_ value: String) -> Bool {
    guard value.hasPrefix("calc("), value.hasSuffix(")") else { return false }
    let expression = value.dropFirst(5).dropLast().filter { !$0.isWhitespace }
    let additionalZeroTerm =
      #"(?:[+-]"# + CSSLengthValuePolicy.unsignedZeroPattern
      + CSSLengthValuePolicy.optionalUnitPattern + ")*"
    return expression.range(
      of: "^" + CSSLengthValuePolicy.zeroLengthPattern + additionalZeroTerm + "$",
      options: .regularExpression
    ) != nil
  }

  private static func isOffCanvasNegativeLengthValue(_ value: String) -> Bool {
    guard isLengthValue(value, for: "margin") else { return false }
    let numericPrefix = value.prefix { "0123456789+-.".contains($0) }
    return Double(numericPrefix).map { $0 <= -100 } == true
  }

  static func isOffCanvasHidden(_ declarations: [StyleDeclaration]) -> Bool {
    if effectiveValue(
      "text-indent", in: declarations,
      where: {
        isLengthValue($0, for: "text-indent")
      }
    ).map(isOffCanvasNegativeLengthValue) == true {
      return true
    }
    return (0..<4).contains { side in
      effectiveMarginValue(side, in: declarations).map(isOffCanvasNegativeLengthValue) == true
    }
  }

  static func simpleCalculatedOpacity(_ value: String) -> Double? {
    guard value.hasPrefix("calc("), value.hasSuffix(")") else { return nil }
    return Double(value.dropFirst(5).dropLast().trimmingCharacters(in: .whitespacesAndNewlines))
  }

  private static func isCSSFunctionValue(_ value: String) -> Bool {
    value.range(
      of: #"^(?:calc|clamp|env|fit-content|max|min|var)\(.+\)$"#,
      options: .regularExpression
    ) != nil
  }

  private static func effectiveMarginValue(
    _ side: Int,
    in declarations: [StyleDeclaration]
  ) -> String? {
    let sideProperty = ["margin-top", "margin-right", "margin-bottom", "margin-left"][side]
    var effectiveDeclaration: (value: String, isImportant: Bool)?
    for declaration in declarations {
      let value: String?
      if declaration.property == sideProperty {
        value = isLengthValue(declaration.value, for: sideProperty) ? declaration.value : nil
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
    value == "auto" || isLengthValue(value, for: "margin")
  }

  private static func isCSSWideKeyword(_ value: String) -> Bool {
    ["inherit", "initial", "revert", "revert-layer", "unset"].contains(value)
  }

  static func declarations(in style: String) -> [StyleDeclaration] {
    style.split(separator: ";").compactMap { declaration in
      let components = declaration.split(separator: ":", maxSplits: 1)
      guard components.count == 2 else { return nil }
      let property = components[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      var value = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
      let importantSuffix = "!important"
      let isImportant = value.lowercased().hasSuffix(importantSuffix)
      if isImportant {
        value.removeLast(importantSuffix.count)
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      guard !property.isEmpty, !value.isEmpty else { return nil }
      return StyleDeclaration(
        property: property,
        value: value.lowercased(),
        isImportant: isImportant
      )
    }
  }

  struct StyleDeclaration {
    let property: String
    let value: String
    let isImportant: Bool
  }
}

extension MessageHTMLSanitizer {
  static func removeOffCanvasRemoteImageMarkers(from document: Document) throws {
    for element in try document.select("[style]") {
      let declarations = MessageHTMLHiddenStylePatterns.declarations(
        in: try element.attr("style")
      )
      guard MessageHTMLHiddenStylePatterns.isOffCanvasHidden(declarations) else { continue }
      if element.hasAttr(RemoteMessageContentMarkup.attribute) {
        try element.removeAttr(RemoteMessageContentMarkup.attribute)
      }
      for descendant in try element.select("[\(RemoteMessageContentMarkup.attribute)]") {
        try descendant.removeAttr(RemoteMessageContentMarkup.attribute)
      }
    }
  }

  static func removePreCleanHiddenElements(from document: Document) throws {
    for element in try document.select("[style]") {
      let declarations = MessageHTMLHiddenStylePatterns.declarations(
        in: try element.attr("style")
      )
      guard MessageHTMLHiddenStylePatterns.isPreCleanHidden(declarations) else { continue }
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
      let declarations = MessageHTMLHiddenStylePatterns.declarations(in: style)
      let isHidden =
        parentIsHidden
        || element.hasAttr("hidden")
        || MessageHTMLHiddenStylePatterns.isPreCleanHidden(declarations)
        || MessageHTMLHiddenStylePatterns.isReadableHidden(declarations)
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
