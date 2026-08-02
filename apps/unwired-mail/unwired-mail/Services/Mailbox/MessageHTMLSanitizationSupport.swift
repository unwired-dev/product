import Foundation
import SwiftSoup

// swiftlint:disable file_length

enum CSSLengthValuePolicy {
  static let initialFontSizePixels = 16.0
  static let unsignedNumberPattern = #"(?:\d+(?:\.\d*)?|\.\d+)(?:e[+-]?\d+)?"#
  static let unitPattern = #"(?:ch|cm|em|ex|in|mm|pc|pt|px|q|rem|vh|vmax|vmin|vw|%)"#
  static let optionalUnitPattern = unitPattern + "?"
  static let unsignedZeroPattern = #"(?:0+(?:\.0*)?|\.0+)"#
  static let zeroLengthPattern = #"[+-]?"# + unsignedZeroPattern + optionalUnitPattern

  static func absolutePixelLengthValue(_ value: String) -> Double? {
    let normalized = value.lowercased()
    let units: [(suffix: String, pixelsPerUnit: Double)] = [
      ("px", 1), ("in", 96), ("cm", 96 / 2.54), ("mm", 96 / 25.4),
      ("pc", 16), ("pt", 96 / 72), ("q", 96 / 101.6),
    ]
    guard let unit = units.first(where: { normalized.hasSuffix($0.suffix) }),
      let number = Double(normalized.dropLast(unit.suffix.count))
    else { return nil }
    return number * unit.pixelsPerUnit
  }
}

extension MessageHTMLHiddenStylePatterns {
  private static let zeroLengthCalculatedUnits = Set([
    "", "%", "ch", "cm", "em", "ex", "in", "mm", "pc", "pt", "px", "q", "rem", "vh",
    "vmax", "vmin", "vw",
  ])

  private struct CalculatedTerm {
    let sign: Double
    let number: Double
    let unit: String
  }

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
    opacityNumberValue(value) != nil || constantCalculatedOpacity(value) != nil
      || isValidVariableOpacity(value) || isCSSWideKeyword(value)
  }

  private static func isValidVariableOpacity(_ value: String) -> Bool {
    guard value.hasPrefix("var("), value.hasSuffix(")") else { return false }
    let argumentsStart = value.index(value.startIndex, offsetBy: 4)
    let argumentsEnd = value.index(before: value.endIndex)
    guard let arguments = calculatedArguments(value[argumentsStart..<argumentsEnd]),
      [1, 2].contains(arguments.count),
      arguments[0].trimmingCharacters(in: .whitespacesAndNewlines).range(
        of: #"^--[a-z0-9_-]+$"#,
        options: [.regularExpression, .caseInsensitive]
      ) != nil
    else { return false }
    return arguments.count == 1
      || !arguments[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  static func isDisplayValue(_ value: String) -> Bool {
    let singleKeywords = Set([
      "block", "contents", "flex", "flow-root", "grid", "inline", "inline-block",
      "inline-flex", "inline-grid", "inline-table", "list-item", "none", "ruby",
      "ruby-base", "ruby-base-container", "ruby-text", "ruby-text-container", "run-in",
      "table", "table-caption", "table-cell", "table-column", "table-column-group",
      "table-footer-group", "table-header-group", "table-row", "table-row-group",
    ])
    let values = value.split(whereSeparator: \Character.isWhitespace).map(String.init)
    if values.count == 1 {
      return isCSSWideKeyword(value) || singleKeywords.contains(value)
    }
    guard Set(values).count == values.count else { return false }
    let outside = Set(["block", "inline", "run-in"])
    let inside = Set(["flow", "flow-root", "table", "flex", "grid", "ruby"])
    let outsideValues = values.filter(outside.contains)
    let insideValues = values.filter(inside.contains)
    let hasListItem = values.contains("list-item")
    guard outsideValues.count <= 1, insideValues.count <= 1,
      values.count == outsideValues.count + insideValues.count + (hasListItem ? 1 : 0)
    else { return false }
    if hasListItem {
      return insideValues.isEmpty || ["flow", "flow-root"].contains(insideValues[0])
    }
    return !outsideValues.isEmpty && !insideValues.isEmpty
  }

  static func isLengthValue(
    _ value: String,
    for property: String,
    remainingDepth: Int = 16
  ) -> Bool {
    if value.range(
      of: "^[+-]?" + CSSLengthValuePolicy.unsignedNumberPattern
        + CSSLengthValuePolicy.optionalUnitPattern + "$",
      options: [.regularExpression, .caseInsensitive]
    ) != nil {
      let isUnitlessNonzero = Double(value).map { $0 != 0 } == true
      return property == "line-height" || !isUnitlessNonzero
    }
    if value == "normal" { return property == "line-height" }
    let sizingProperties = [
      "height", "max-height", "max-width", "min-height", "min-width", "width",
    ]
    switch value {
    case "auto":
      return ["height", "min-height", "min-width", "width"].contains(property)
    case "fit-content", "max-content", "min-content":
      return sizingProperties.contains(property)
    case "none":
      return ["max-height", "max-width"].contains(property)
    default:
      return isCSSWideKeyword(value)
        || isValidLengthFunctionValue(value, remainingDepth: remainingDepth - 1)
    }
  }

  static func isZeroLengthValue(_ value: String) -> Bool {
    value.range(
      of: "^" + CSSLengthValuePolicy.zeroLengthPattern + "$",
      options: .regularExpression
    ) != nil
      || isCalculatedZeroLengthValue(value)
      || pixelLengthValue(value).map { abs($0) < 0.000_000_001 } == true
  }

  static func isOnePixelLengthValue(_ value: String) -> Bool {
    if CSSLengthValuePolicy.absolutePixelLengthValue(value).map({
      abs($0 - 1) < 0.000_000_001
    }) == true {
      return true
    }
    return simpleCalculatedPixelLengthValue(value).map {
      abs($0 - 1) < 0.000_000_001
    } == true
  }

  static func pixelLengthValue(_ value: String) -> Double? {
    CSSLengthValuePolicy.absolutePixelLengthValue(value)
      ?? constantCalculatedPixelLengthValue(value)
  }

  static func isOnePixelLengthValue(
    _ value: String,
    fontSizePixels: Double?
  ) -> Bool {
    pixelLengthValue(value, fontSizePixels: fontSizePixels).map {
      abs($0 - 1) < 0.000_000_001
    } == true
  }

  static func pixelLengthValue(
    _ value: String,
    fontSizePixels: Double?
  ) -> Double? {
    if let pixels = pixelLengthValue(value) { return pixels }
    let normalized = value.lowercased()
    if normalized.hasSuffix("rem"),
      let multiplier = Double(normalized.dropLast(3))
    {
      return multiplier * CSSLengthValuePolicy.initialFontSizePixels
    }
    guard let fontSizePixels, normalized.hasSuffix("em"),
      let multiplier = Double(normalized.dropLast(2))
    else { return nil }
    return multiplier * fontSizePixels
  }

  static func simpleCalculatedPixelLengthValue(_ value: String) -> Double? {
    guard let terms = simpleCalculatedTerms(value) else { return nil }
    var total = 0.0
    for term in terms {
      guard
        term.unit == "px"
          || (term.number == 0 && zeroLengthCalculatedUnits.contains(term.unit))
      else { return nil }
      if term.unit == "px" { total += term.sign * term.number }
    }
    return total
  }

  static func calculatedPixelLengthValue(
    _ value: String,
    percentageBasePixels: Double,
    fontSizePixels: Double?
  ) -> Double? {
    guard let terms = simpleCalculatedTerms(value) else { return nil }
    var total = 0.0
    for term in terms {
      if term.unit == "%" {
        total += term.sign * term.number * percentageBasePixels / 100
      } else if term.unit.isEmpty, term.number == 0 {
        continue
      } else {
        if term.number == 0, zeroLengthCalculatedUnits.contains(term.unit) { continue }
        guard let pixelsPerUnit = pixelsPerUnit(term.unit, fontSizePixels: fontSizePixels)
        else { return nil }
        total += term.sign * term.number * pixelsPerUnit
      }
    }
    return total.isFinite ? total : nil
  }

  private static func constantCalculatedPixelLengthValue(
    _ value: String,
    remainingDepth: Int = 16
  ) -> Double? {
    guard remainingDepth > 0 else { return nil }
    if let value = simpleCalculatedPixelLengthValue(value) { return value }
    let normalized = value.lowercased()
    guard let openingParenthesis = normalized.firstIndex(of: "("), normalized.hasSuffix(")")
    else { return nil }
    let function = String(normalized[..<openingParenthesis])
    guard ["calc", "clamp", "max", "min"].contains(function) else { return nil }
    let argumentsStart = normalized.index(after: openingParenthesis)
    let argumentsEnd = normalized.index(before: normalized.endIndex)
    guard let arguments = calculatedArguments(normalized[argumentsStart..<argumentsEnd])
    else { return nil }
    var values: [Double] = []
    for argument in arguments {
      let argument = argument.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !argument.isEmpty,
        let value = CSSLengthValuePolicy.absolutePixelLengthValue(argument)
          ?? simpleCalculatedPixelLengthValue(argument)
          ?? constantCalculatedPixelLengthValue(argument, remainingDepth: remainingDepth - 1)
      else { return nil }
      values.append(value)
    }
    return constantFunctionValue(function, values: values)
  }

  private static func calculatedArguments(_ expression: Substring) -> [String]? {
    var arguments = [""]
    var depth = 0
    for character in expression {
      if character == "(" { depth += 1 }
      if character == ")" { depth -= 1 }
      guard depth >= 0 else { return nil }
      if character == ",", depth == 0 {
        arguments.append("")
      } else {
        arguments[arguments.count - 1].append(character)
      }
    }
    return depth == 0 ? arguments : nil
  }

  private static func constantFunctionValue(_ function: String, values: [Double]) -> Double? {
    switch function {
    case "calc":
      guard values.count == 1 else { return nil }
      return values[0]
    case "min": return values.min()
    case "max": return values.max()
    default:
      guard values.count == 3 else { return nil }
      return Swift.max(values[0], Swift.min(values[1], values[2]))
    }
  }

  private static func isCalculatedZeroLengthValue(_ value: String) -> Bool {
    guard value.hasPrefix("calc("), value.hasSuffix(")") else { return false }
    return simpleCalculatedPixelLengthValue(value).map { abs($0) < 0.000_000_001 } == true
  }

  private static func isOffCanvasNegativeLengthValue(_ value: String) -> Bool {
    guard isLengthValue(value, for: "margin") else { return false }
    if let calculatedValue = pixelLengthValue(value) {
      return calculatedValue <= -100
    }
    let numericPrefix = value.prefix { "0123456789+-.".contains($0) }
    return Double(numericPrefix).map { $0 <= -100 } == true
  }

  static func isOffCanvasHidden(
    _ declarations: [StyleDeclaration],
    in element: Element? = nil,
    precedingFlowPixels knownPrecedingFlowPixels: Double? = nil
  ) -> Bool {
    if element?.tagName().lowercased() != "img",
      let textIndent = effectiveValue(
        "text-indent", in: declarations,
        where: {
          isLengthValue($0, for: "text-indent")
        }
      ),
      isOffCanvasNegativeLengthValue(textIndent)
    {
      guard let textIndentPixels = pixelLengthValue(textIndent) else { return true }
      if accumulatedPaddingPixels(from: element, side: 3) + textIndentPixels < 0 {
        return true
      }
    }
    for side in [0, 3] {
      guard
        let margin = effectiveMarginValue(side, in: declarations),
        isOffCanvasNegativeLengthValue(margin)
      else { continue }
      guard let marginPixels = pixelLengthValue(margin) else { return true }
      let precedingFlowPixels: Double
      if side == 0 {
        guard
          let resolvedPrecedingFlowPixels =
            knownPrecedingFlowPixels ?? Self.precedingFlowPixels(before: element)
        else { continue }
        precedingFlowPixels = resolvedPrecedingFlowPixels
      } else {
        guard let resolvedPrecedingFlowPixels = precedingInlineFlowPixels(before: element) else {
          continue
        }
        precedingFlowPixels = resolvedPrecedingFlowPixels
      }
      if accumulatedPaddingPixels(from: element?.parent(), side: side) + precedingFlowPixels
        + marginPixels < 0
      {
        return true
      }
    }
    return false
  }

  private static func accumulatedPaddingPixels(from element: Element?, side: Int) -> Double {
    var current = element
    var paddingPixels = 0.0
    while let element = current {
      let declarations = Self.declarations(in: (try? element.attr("style")) ?? "")
      if let padding = effectivePaddingValue(side, in: declarations),
        let pixels = pixelLengthValue(padding)
      {
        paddingPixels += pixels
      }
      current = element.parent()
    }
    return paddingPixels
  }

  private static func precedingFlowPixels(before element: Element?) -> Double? {
    var sibling = try? element?.previousElementSibling()
    var pixels = 0.0
    while let current = sibling {
      let declarations = Self.declarations(in: (try? current.attr("style")) ?? "")
      guard let contribution = precedingFlowHeightPixels(in: declarations, for: current) else {
        return nil
      }
      pixels += contribution
      sibling = try? current.previousElementSibling()
    }
    return pixels
  }

  private static func precedingInlineFlowPixels(before element: Element?) -> Double? {
    var sibling = element?.previousSibling()
    while let current = sibling {
      if let textNode = current as? TextNode,
        !textNode.getWholeText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        return nil
      }
      if let current = current as? Element {
        let declarations = Self.declarations(in: (try? current.attr("style")) ?? "")
        let display = effectiveValue("display", in: declarations, where: isDisplayValue)
        if display == "contents" || display?.hasPrefix("inline") == true
          || !dimensionsApply(to: current)
          || isDefaultInlineReplacedElement(current, display: display)
        {
          return nil
        }
      }
      sibling = current.previousSibling()
    }
    return 0
  }

  private static func isDefaultInlineReplacedElement(_ element: Element, display: String?) -> Bool {
    guard display == nil else { return false }
    return [
      "audio", "button", "canvas", "embed", "iframe", "img", "input", "object", "select",
      "textarea", "video",
    ]
    .contains(element.tagName().lowercased())
  }

  static func precedingFlowHeightPixels(
    in declarations: [StyleDeclaration],
    for element: Element? = nil
  ) -> Double? {
    let display = effectiveValue("display", in: declarations, where: isDisplayValue)
    guard !["contents", "inline"].contains(display) else { return 0 }
    if element.map({ !dimensionsApply(to: $0) }) == true { return 0 }
    guard
      effectivePaddingValue(0, in: declarations) == nil,
      effectivePaddingValue(2, in: declarations) == nil,
      effectiveBorderWidthValue(0, in: declarations) == nil,
      effectiveBorderWidthValue(2, in: declarations) == nil,
      effectiveValue(
        "min-height", in: declarations,
        where: { isLengthValue($0, for: "min-height") }
      ) == nil,
      effectiveValue(
        "max-height", in: declarations,
        where: { isLengthValue($0, for: "max-height") }
      ) == nil
    else { return nil }
    guard
      let height = effectiveValue(
        "height", in: declarations,
        where: {
          isLengthValue($0, for: "height")
        }), let heightPixels = pixelLengthValue(height)
    else { return nil }
    return Swift.max(0, heightPixels)
  }

  static func constantCalculatedOpacity(
    _ value: String,
    remainingDepth: Int = 16
  ) -> Double? {
    guard remainingDepth > 0 else { return nil }
    if let value = simpleCalculatedOpacity(value) { return value }
    let normalized = value.lowercased()
    guard let openingParenthesis = normalized.firstIndex(of: "("), normalized.hasSuffix(")")
    else { return nil }
    let function = String(normalized[..<openingParenthesis])
    if function == "var" {
      return validVariableOpacityFallback(
        normalized,
        remainingDepth: remainingDepth - 1
      )
    }
    guard ["calc", "clamp", "max", "min"].contains(function) else { return nil }
    let argumentsStart = normalized.index(after: openingParenthesis)
    let argumentsEnd = normalized.index(before: normalized.endIndex)
    guard let arguments = calculatedArguments(normalized[argumentsStart..<argumentsEnd])
    else { return nil }
    var values: [Double] = []
    for argument in arguments {
      let argument = argument.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !argument.isEmpty,
        let value = opacityValue(argument, remainingDepth: remainingDepth - 1)
      else { return nil }
      values.append(value)
    }
    guard let value = constantFunctionValue(function, values: values), value.isFinite else {
      return nil
    }
    return value
  }

  private static func opacityValue(_ value: String, remainingDepth: Int) -> Double? {
    if let calculated = simpleCalculatedOpacity(value) { return calculated }
    return opacityNumberValue(value)
      ?? constantCalculatedOpacity(value, remainingDepth: remainingDepth)
  }

  private static func validVariableOpacityFallback(
    _ value: String,
    remainingDepth: Int
  ) -> Double? {
    guard remainingDepth > 0 else { return nil }
    let normalized = value.lowercased()
    guard normalized.hasPrefix("var("), normalized.hasSuffix(")") else { return nil }
    let argumentsStart = normalized.index(normalized.startIndex, offsetBy: 4)
    let argumentsEnd = normalized.index(before: normalized.endIndex)
    guard let arguments = calculatedArguments(normalized[argumentsStart..<argumentsEnd]),
      arguments.count == 2,
      arguments[0].trimmingCharacters(in: .whitespacesAndNewlines).range(
        of: #"^--[a-z0-9_-]+$"#,
        options: [.regularExpression, .caseInsensitive]
      ) != nil
    else { return nil }
    let fallback = arguments[1].trimmingCharacters(in: .whitespacesAndNewlines)
    return opacityValue(fallback, remainingDepth: remainingDepth)
  }

  static func opacityNumberValue(_ value: String) -> Double? {
    let isPercentage = value.hasSuffix("%")
    let number = isPercentage ? String(value.dropLast()) : value
    guard
      number.range(
        of: #"^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:e[+-]?\d+)?$"#,
        options: [.regularExpression, .caseInsensitive]
      ) != nil,
      let parsed = Double(number), parsed.isFinite
    else { return nil }
    return isPercentage ? parsed / 100 : parsed
  }

  static func simpleCalculatedOpacity(_ value: String) -> Double? {
    guard let terms = simpleCalculatedTerms(value) else { return nil }
    guard terms.allSatisfy({ $0.unit.isEmpty || $0.unit == "%" }) else { return nil }
    let value = terms.reduce(0) { total, term in
      total + term.sign * (term.unit == "%" ? term.number / 100 : term.number)
    }
    return value.isFinite ? value : nil
  }

  // swiftlint:disable:next cyclomatic_complexity function_body_length
  private static func simpleCalculatedTerms(
    _ value: String
  ) -> [CalculatedTerm]? {
    let normalized = value.lowercased()
    guard normalized.hasPrefix("calc("), normalized.hasSuffix(")") else { return nil }
    let rawExpression = normalized.dropFirst(5).dropLast()
    var binaryExpression = rawExpression.drop(while: { $0.isWhitespace })
    if binaryExpression.first == "+" || binaryExpression.first == "-" {
      binaryExpression = binaryExpression.dropFirst()
    }
    guard
      binaryExpression.range(
        of: #"(?<=\S)[+-]|[+-](?=\S)"#,
        options: .regularExpression
      ) == nil
    else { return nil }
    let expression = Array(rawExpression.filter { !$0.isWhitespace })
    guard !expression.isEmpty else { return nil }
    var index = 0
    var termCount = 0
    var terms: [CalculatedTerm] = []
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
        let number = Double(String(expression[numberStart..<index])), number.isFinite
      else { return nil }
      let unitStart = index
      while index < expression.count,
        expression[index].isLetter || expression[index] == "%"
      {
        index += 1
      }
      terms.append(
        CalculatedTerm(
          sign: sign,
          number: number,
          unit: String(expression[unitStart..<index])
        )
      )
      termCount += 1
    }
    return terms
  }

  static func isCSSFunctionValue(_ value: String) -> Bool {
    value.range(
      of: #"^(?:calc|clamp|env|fit-content|max|min|var)\(.+\)$"#,
      options: .regularExpression
    ) != nil
  }

  // swiftlint:disable:next function_body_length
  private static func isValidLengthFunctionValue(
    _ value: String,
    remainingDepth: Int
  ) -> Bool {
    guard remainingDepth > 0, isCSSFunctionValue(value),
      let openingParenthesis = value.firstIndex(of: "(")
    else {
      return false
    }
    let function = String(value[..<openingParenthesis])
    let argumentsStart = value.index(after: openingParenthesis)
    let argumentsEnd = value.index(before: value.endIndex)
    guard let arguments = calculatedArguments(value[argumentsStart..<argumentsEnd]) else {
      return false
    }
    if function == "var" {
      guard [1, 2].contains(arguments.count),
        arguments[0].trimmingCharacters(in: .whitespacesAndNewlines).range(
          of: #"^--[a-z0-9_-]+$"#,
          options: [.regularExpression, .caseInsensitive]
        ) != nil
      else { return false }
      return arguments.count == 1
        || !arguments[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    if function == "env" {
      return [1, 2].contains(arguments.count)
        && !arguments[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && (arguments.count == 1
          || !arguments[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    if function == "fit-content" {
      return arguments.count == 1
        && isLengthValue(
          arguments[0].trimmingCharacters(in: .whitespacesAndNewlines),
          for: "width",
          remainingDepth: remainingDepth - 1
        )
    }
    guard
      (function == "calc" && arguments.count == 1)
        || (["max", "min"].contains(function) && !arguments.isEmpty)
        || (function == "clamp" && arguments.count == 3)
    else { return false }
    if constantCalculatedPixelLengthValue(value) != nil { return true }
    let customPropertiesRemoved = value.replacingOccurrences(
      of: #"--[a-z0-9_-]+"#,
      with: "",
      options: [.regularExpression, .caseInsensitive]
    )
    let identifierPattern = #"[a-z][a-z0-9-]*"#
    var identifierSearch = customPropertiesRemoved
    var identifiers: [String] = []
    while let range = identifierSearch.range(
      of: identifierPattern,
      options: [.regularExpression, .caseInsensitive]
    ) {
      identifiers.append(String(identifierSearch[range]).lowercased())
      identifierSearch = String(identifierSearch[range.upperBound...])
    }
    let allowedIdentifiers = Set([
      "calc", "ch", "clamp", "cm", "em", "env", "ex", "in", "max", "min", "mm",
      "pc", "pt", "px", "q", "rem", "var", "vh", "vmax", "vmin", "vw",
    ])
    let hasNumericValue = value.range(of: #"\d"#, options: .regularExpression) != nil
    return (hasNumericValue || identifiers.contains("env") || identifiers.contains("var"))
      && identifiers.allSatisfy(allowedIdentifiers.contains)
  }

  static func effectiveMarginValue(
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

  static func effectivePaddingValue(
    _ side: Int,
    in declarations: [StyleDeclaration]
  ) -> String? {
    let sideProperty = ["padding-top", "padding-right", "padding-bottom", "padding-left"][side]
    var effectiveDeclaration: (value: String, isImportant: Bool)?
    for declaration in declarations {
      let value: String?
      if declaration.property == sideProperty {
        value = isPaddingValue(declaration.value) ? declaration.value : nil
      } else if declaration.property == "padding" {
        value = paddingValues(declaration.value)?[side]
      } else {
        continue
      }
      guard let value else { continue }
      if effectiveDeclaration?.isImportant == true, !declaration.isImportant { continue }
      effectiveDeclaration = (value, declaration.isImportant)
    }
    return effectiveDeclaration?.value
  }

  static func effectiveBorderWidthValue(
    _ side: Int,
    in declarations: [StyleDeclaration]
  ) -> String? {
    let sideName = ["top", "right", "bottom", "left"][side]
    let sideProperty = "border-\(sideName)"
    var effectiveDeclaration: (value: String, isImportant: Bool)?
    for declaration in declarations {
      let value: String?
      switch declaration.property {
      case "\(sideProperty)-width":
        value = normalizedBorderWidthValue(declaration.value)
      case "border-width":
        value = borderWidthValues(declaration.value)?[side]
      case sideProperty, "border":
        value = borderShorthandValues(declaration.value).map { $0.width ?? "3px" }
      default:
        continue
      }
      guard let value else { continue }
      if effectiveDeclaration?.isImportant == true, !declaration.isImportant { continue }
      effectiveDeclaration = (value, declaration.isImportant)
    }
    return effectiveDeclaration?.value
  }

  static func effectiveBorderStyleValue(
    _ side: Int,
    in declarations: [StyleDeclaration]
  ) -> String? {
    let sideName = ["top", "right", "bottom", "left"][side]
    let sideProperty = "border-\(sideName)"
    var effectiveDeclaration: (value: String, isImportant: Bool)?
    for declaration in declarations {
      let value: String?
      switch declaration.property {
      case "\(sideProperty)-style":
        value = isBorderStyleValue(declaration.value) ? declaration.value : nil
      case "border-style":
        value = borderStyleValues(declaration.value)?[side]
      case sideProperty, "border":
        value = borderShorthandValues(declaration.value).map { $0.style ?? "none" }
      default:
        continue
      }
      guard let value else { continue }
      if effectiveDeclaration?.isImportant == true, !declaration.isImportant { continue }
      effectiveDeclaration = (value, declaration.isImportant)
    }
    return effectiveDeclaration?.value
  }

  static func horizontalInsetPixels(
    in declarations: [StyleDeclaration],
    percentageBasePixels: Double,
    fontSizePixels: Double?
  ) -> Double {
    var pixels = 0.0
    for side in [1, 3] {
      for inset in [
        effectiveMarginValue(side, in: declarations),
        effectivePaddingValue(side, in: declarations),
      ] {
        if let inset,
          let insetPixels = insetPixelLengthValue(
            inset,
            percentageBasePixels: percentageBasePixels,
            fontSizePixels: fontSizePixels
          )
        {
          pixels += insetPixels
        }
      }
      if effectiveBorderStyleValue(side, in: declarations).map({
        !["hidden", "none"].contains($0)
      }) == true,
        let borderWidth = effectiveBorderWidthValue(side, in: declarations),
        let borderPixels = pixelLengthValue(borderWidth, fontSizePixels: fontSizePixels)
      {
        pixels += borderPixels
      }
    }
    return pixels
  }

  private static func marginValues(_ value: String) -> [String]? {
    guard let values = whitespaceSeparatedCSSComponents(value) else { return nil }
    guard (1...4).contains(values.count), values.allSatisfy(isMarginValue) else { return nil }
    switch values.count {
    case 1: return [values[0], values[0], values[0], values[0]]
    case 2: return [values[0], values[1], values[0], values[1]]
    case 3: return [values[0], values[1], values[2], values[1]]
    default: return values
    }
  }

  private static func paddingValues(_ value: String) -> [String]? {
    guard let values = whitespaceSeparatedCSSComponents(value) else { return nil }
    guard (1...4).contains(values.count), values.allSatisfy(isPaddingValue) else { return nil }
    return expandedBoxValues(values)
  }

  private static func borderWidthValues(_ value: String) -> [String]? {
    guard let values = whitespaceSeparatedCSSComponents(value) else { return nil }
    guard (1...4).contains(values.count) else { return nil }
    let normalizedValues = values.compactMap(normalizedBorderWidthValue)
    guard normalizedValues.count == values.count else { return nil }
    return expandedBoxValues(normalizedValues)
  }

  private static func borderStyleValues(_ value: String) -> [String]? {
    guard let values = whitespaceSeparatedCSSComponents(value) else { return nil }
    guard (1...4).contains(values.count), values.allSatisfy(isBorderStyleValue) else { return nil }
    return expandedBoxValues(values)
  }

  private static func borderShorthandValues(_ value: String) -> (width: String?, style: String?)? {
    guard let components = whitespaceSeparatedCSSComponents(value) else { return nil }
    guard (1...3).contains(components.count) else { return nil }
    var width: String?
    var style: String?
    var hasColor = false
    for component in components {
      if let normalizedWidth = normalizedBorderWidthValue(component) {
        guard width == nil else { return nil }
        width = normalizedWidth
      } else if isBorderStyleValue(component) {
        guard style == nil else { return nil }
        style = component
      } else if isBorderColorValue(component) {
        guard !hasColor else { return nil }
        hasColor = true
      } else {
        return nil
      }
    }
    return (width, style)
  }

  private static func whitespaceSeparatedCSSComponents(_ value: String) -> [String]? {
    var components: [String] = []
    var component = ""
    var parenthesisDepth = 0

    for character in value {
      if character == "(" {
        component.append(character)
        parenthesisDepth += 1
      } else if character == ")" {
        guard parenthesisDepth > 0 else { return nil }
        component.append(character)
        parenthesisDepth -= 1
      } else if character.isWhitespace, parenthesisDepth == 0 {
        if !component.isEmpty {
          components.append(component)
          component = ""
        }
      } else {
        component.append(character)
      }
    }
    guard parenthesisDepth == 0 else { return nil }
    if !component.isEmpty { components.append(component) }
    return components
  }

  private static func expandedBoxValues(_ values: [String]) -> [String] {
    switch values.count {
    case 1: return [values[0], values[0], values[0], values[0]]
    case 2: return [values[0], values[1], values[0], values[1]]
    case 3: return [values[0], values[1], values[2], values[1]]
    default: return values
    }
  }

  private static func insetPixelLengthValue(
    _ value: String,
    percentageBasePixels: Double,
    fontSizePixels: Double?
  ) -> Double? {
    if value.hasSuffix("%"), let percentage = Double(value.dropLast()) {
      return percentageBasePixels * percentage / 100
    }
    if value.hasPrefix("calc("), value.contains("%") {
      return calculatedPixelLengthValue(
        value,
        percentageBasePixels: percentageBasePixels,
        fontSizePixels: fontSizePixels
      )
    }
    return pixelLengthValue(value, fontSizePixels: fontSizePixels)
  }

  private static func pixelsPerUnit(_ unit: String, fontSizePixels: Double?) -> Double? {
    if unit == "rem" { return CSSLengthValuePolicy.initialFontSizePixels }
    if unit == "em" { return fontSizePixels }
    return CSSLengthValuePolicy.absolutePixelLengthValue("1\(unit)")
  }

  private static func normalizedCSSIdentifier(_ value: String) -> String? {
    let characters = Array(value)
    var result = ""
    var index = 0
    while index < characters.count {
      guard characters[index] == "\\" else {
        result.append(characters[index])
        index += 1
        continue
      }
      index += 1
      guard index < characters.count else { return nil }
      var digits = ""
      while index < characters.count, digits.count < 6,
        characters[index].isHexDigit
      {
        digits.append(characters[index])
        index += 1
      }
      if digits.isEmpty {
        guard !characters[index].isNewline else { return nil }
        result.append(characters[index])
        index += 1
        continue
      }
      guard let value = UInt32(digits, radix: 16), let scalar = UnicodeScalar(value),
        value != 0, !(0xD800...0xDFFF).contains(value)
      else { return nil }
      result.unicodeScalars.append(scalar)
      if index < characters.count, characters[index].isWhitespace { index += 1 }
    }
    return result.lowercased()
  }

  private static func isPaddingValue(_ value: String) -> Bool {
    guard isLengthValue(value, for: "padding") else { return false }
    if let pixels = pixelLengthValue(value) { return pixels >= 0 }
    let numericPrefix = value.prefix { "0123456789+-.".contains($0) }
    return Double(numericPrefix).map { $0 >= 0 } ?? true
  }

  private static func normalizedBorderWidthValue(_ value: String) -> String? {
    switch value {
    case "thin": return "1px"
    case "medium": return "3px"
    case "thick": return "5px"
    default:
      guard isLengthValue(value, for: "border-width") else { return nil }
      if let pixels = pixelLengthValue(value) { return pixels >= 0 ? value : nil }
      let numericPrefix = value.prefix { "0123456789+-.".contains($0) }
      guard Double(numericPrefix).map({ $0 >= 0 }) != false else { return nil }
      return value
    }
  }

  private static func isBorderStyleValue(_ value: String) -> Bool {
    ["dashed", "dotted", "double", "groove", "hidden", "inset", "none", "outset", "ridge", "solid"]
      .contains(value)
  }

  private static let namedBorderColors = Set(
    """
      aliceblue antiquewhite aqua aquamarine azure beige bisque black blanchedalmond blue
      blueviolet brown burlywood cadetblue chartreuse chocolate coral cornflowerblue cornsilk
      crimson currentcolor cyan darkblue darkcyan darkgoldenrod darkgray darkgreen darkgrey darkkhaki
      darkmagenta darkolivegreen darkorange darkorchid darkred darksalmon darkseagreen darkslateblue
      darkslategray darkslategrey darkturquoise darkviolet deeppink deepskyblue dimgray dimgrey
      dodgerblue firebrick floralwhite forestgreen fuchsia gainsboro ghostwhite gold goldenrod gray
      green greenyellow grey honeydew hotpink indianred indigo ivory khaki lavender lavenderblush
      lawngreen lemonchiffon lightblue lightcoral lightcyan lightgoldenrodyellow lightgray lightgreen
      lightgrey lightpink lightsalmon lightseagreen lightskyblue lightslategray lightslategrey
      lightsteelblue lightyellow lime limegreen linen magenta maroon mediumaquamarine mediumblue
      mediumorchid mediumpurple mediumseagreen mediumslateblue mediumspringgreen mediumturquoise
      mediumvioletred midnightblue mintcream mistyrose moccasin navajowhite navy oldlace olive
      olivedrab orange orangered orchid palegoldenrod palegreen paleturquoise palevioletred
      papayawhip peachpuff peru pink plum powderblue purple rebeccapurple red rosybrown royalblue
      saddlebrown salmon sandybrown seagreen seashell sienna silver skyblue slateblue slategray
      slategrey snow springgreen steelblue tan teal thistle tomato transparent turquoise violet wheat
      white whitesmoke yellow yellowgreen
      accentcolor accentcolortext activetext buttonborder buttonface buttontext canvas canvastext
      field fieldtext graytext highlight highlighttext linktext mark marktext selecteditem
      selecteditemtext visitedtext
    """.split(whereSeparator: \Character.isWhitespace).map(String.init)
  )

  private static func isBorderColorValue(_ value: String) -> Bool {
    namedBorderColors.contains(value)
      || value.range(
        of: #"^#(?:[0-9a-f]{3}|[0-9a-f]{4}|[0-9a-f]{6}|[0-9a-f]{8})$"#,
        options: .regularExpression
      ) != nil
      || isFunctionalBorderColorValue(value)
  }

  // swiftlint:disable:next function_body_length
  private static func isFunctionalBorderColorValue(_ value: String) -> Bool {
    guard let openingParenthesis = value.firstIndex(of: "("), value.hasSuffix(")") else {
      return false
    }
    let function = String(value[..<openingParenthesis])
    let body = String(
      value[value.index(after: openingParenthesis)..<value.index(before: value.endIndex)]
    )
    .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { return false }
    if function == "var" {
      return body.range(
        of: #"^--[a-z0-9_-]+(?:\s*,[\s\S]+)?$"#,
        options: .regularExpression
      ) != nil
    }
    if function == "light-dark" {
      guard let arguments = calculatedArguments(body[...]), arguments.count == 2 else {
        return false
      }
      return arguments.allSatisfy {
        isBorderColorValue($0.trimmingCharacters(in: .whitespacesAndNewlines))
      }
    }
    if function == "color-mix" {
      guard let arguments = calculatedArguments(body[...]), arguments.count == 3,
        arguments[0].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("in ")
      else { return false }
      return arguments.dropFirst().allSatisfy { argument in
        let color = argument.trimmingCharacters(in: .whitespacesAndNewlines)
          .replacingOccurrences(
            of: #"\s+[+-]?(?:\d+(?:\.\d*)?|\.\d+)%\s*$"#,
            with: "",
            options: .regularExpression
          )
        return isBorderColorValue(color)
      }
    }
    let numericFunctions = Set([
      "hsl", "hsla", "hwb", "lab", "lch", "oklab", "oklch", "rgb", "rgba",
    ])
    guard numericFunctions.contains(function) else {
      guard function == "color" else { return false }
      let components = body.replacingOccurrences(of: "/", with: " ")
        .split(whereSeparator: \Character.isWhitespace)
      let colorSpaces = Set([
        "a98-rgb", "display-p3", "prophoto-rgb", "rec2020", "srgb", "srgb-linear", "xyz",
        "xyz-d50", "xyz-d65",
      ])
      guard (4...5).contains(components.count), colorSpaces.contains(String(components[0])) else {
        return false
      }
      return components.dropFirst().allSatisfy { isColorComponent(String($0)) }
    }
    let components = body.replacingOccurrences(of: ",", with: " ")
      .replacingOccurrences(of: "/", with: " ")
      .split(whereSeparator: \Character.isWhitespace)
    return (3...4).contains(components.count)
      && components.allSatisfy { isColorComponent(String($0)) }
  }

  private static func isColorComponent(_ value: String) -> Bool {
    value == "none"
      || value.range(
        of: #"^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:e[+-]?\d+)?(?:%|deg|grad|rad|turn)?$"#,
        options: [.regularExpression, .caseInsensitive]
      ) != nil
  }

  private static func isMarginValue(_ value: String) -> Bool {
    value == "auto" || isLengthValue(value, for: "margin")
  }

  private static func isCSSWideKeyword(_ value: String) -> Bool {
    ["inherit", "initial", "revert", "revert-layer", "unset"].contains(value)
  }

  static func declarations(in style: String) -> [StyleDeclaration] {
    let normalizedStyle = style.replacingOccurrences(
      of: #"/\*[\s\S]*?\*/"#,
      with: " ",
      options: .regularExpression
    )
    return splitStyleDeclarations(normalizedStyle).compactMap { declaration in
      let components = declaration.split(separator: ":", maxSplits: 1)
      guard components.count == 2 else { return nil }
      let property = components[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      var value = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
      let importantPattern = #"!\s*(?:/\*[\s\S]*?\*/\s*)*important\s*$"#
      let importantRange = value.range(
        of: importantPattern,
        options: [.regularExpression, .caseInsensitive]
      )
      if let importantRange {
        value.removeSubrange(importantRange)
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      guard !property.isEmpty, !value.isEmpty else { return nil }
      let normalizedValue = value.lowercased()
      return StyleDeclaration(
        property: property,
        value: property == "visibility"
          ? (normalizedCSSIdentifier(normalizedValue) ?? normalizedValue)
          : normalizedValue,
        isImportant: importantRange != nil
      )
    }
  }

  private static func splitStyleDeclarations(_ style: String) -> [String] {
    var declarations: [String] = []
    var declaration = ""
    var quote: Character?
    var isEscaped = false
    for character in style {
      if isEscaped {
        declaration.append(character)
        isEscaped = false
      } else if character == "\\" {
        declaration.append(character)
        isEscaped = true
      } else if let activeQuote = quote {
        declaration.append(character)
        if character == activeQuote { quote = nil }
      } else if character == "\"" || character == "'" {
        declaration.append(character)
        quote = character
      } else if character == ";" {
        declarations.append(declaration)
        declaration = ""
      } else {
        declaration.append(character)
      }
    }
    declarations.append(declaration)
    return declarations
  }

  struct StyleDeclaration {
    let property: String
    let value: String
    let isImportant: Bool
  }
}

extension MessageHTMLSanitizer {
  static func removeOffCanvasRemoteImageMarkers(from document: Document) throws {
    try NodeTraversor(OffCanvasRemoteImageMarkerVisitor()).traverse(document)
  }

  // swiftlint:disable:next function_body_length
  static func removePreCleanHiddenElements(
    from document: Document,
    cancellationCheck: () throws -> Void
  ) throws {
    var elementsInRemovedSubtrees = Set<ObjectIdentifier>()
    for element in try document.select("[style]") {
      if elementsInRemovedSubtrees.contains(ObjectIdentifier(element)) { continue }
      try cancellationCheck()
      let declarations = MessageHTMLHiddenStylePatterns.declarations(
        in: try element.attr("style")
      )
      guard MessageHTMLHiddenStylePatterns.isPreCleanHidden(declarations) else { continue }
      let styledDescendants = try element.select("[style]").filter { $0 !== element }
      for descendant in styledDescendants {
        elementsInRemovedSubtrees.insert(ObjectIdentifier(descendant))
      }
      let visibility = MessageHTMLHiddenStylePatterns.effectiveValue(
        "visibility",
        in: declarations,
        where: MessageHTMLHiddenStylePatterns.isVisibilityValue
      )
      let nonVisibilityDeclarations = declarations.filter { $0.property != "visibility" }
      let isHiddenOnlyByVisibility =
        (visibility == "hidden"
          || (visibility == "collapse" && !isCollapsedTableTrack(element)))
        && !element.hasAttr("hidden")
        && !MessageHTMLHiddenStylePatterns.isPreCleanHidden(nonVisibilityDeclarations)
        && !MessageHTMLHiddenStylePatterns.isPresentationHidden(
          nonVisibilityDeclarations, in: element)
        && !MessageHTMLHiddenStylePatterns.isReadableHidden(nonVisibilityDeclarations)
      if isHiddenOnlyByVisibility {
        let visibleDescendants = try styledDescendants.filter { descendant in
          let descendantVisibility = MessageHTMLHiddenStylePatterns.effectiveValue(
            "visibility",
            in: MessageHTMLHiddenStylePatterns.declarations(
              in: try descendant.attr("style")
            ),
            where: MessageHTMLHiddenStylePatterns.isVisibilityValue
          )
          guard ["initial", "visible"].contains(descendantVisibility) else {
            return false
          }
          return try canPromoteVisibleDescendant(descendant, from: element)
        }
        for descendant in visibleDescendants {
          let promotedDocument = try SwiftSoup.parseBodyFragment(descendant.outerHtml())
          try removePreCleanHiddenElements(
            from: promotedDocument,
            cancellationCheck: cancellationCheck
          )
          try element.before(promotedDocument.body()?.html() ?? "")
        }
      }
      try element.remove()
    }
  }

  private static func isCollapsedTableTrack(_ element: Element) -> Bool {
    if ["col", "colgroup", "tbody", "tfoot", "thead", "tr"].contains(
      element.tagName().lowercased()
    ) {
      return true
    }
    let display = MessageHTMLHiddenStylePatterns.effectiveValue(
      "display",
      in: MessageHTMLHiddenStylePatterns.declarations(
        in: (try? element.attr("style")) ?? ""
      ),
      where: MessageHTMLHiddenStylePatterns.isDisplayValue
    )
    return [
      "table-column", "table-column-group", "table-footer-group", "table-header-group",
      "table-row", "table-row-group",
    ].contains(display)
  }

  private static func canPromoteVisibleDescendant(
    _ element: Element,
    from hiddenAncestor: Element
  ) throws -> Bool {
    let declarations = MessageHTMLHiddenStylePatterns.declarations(in: try element.attr("style"))
    let nonVisibilityDeclarations = declarations.filter { $0.property != "visibility" }
    guard !element.hasAttr("hidden"),
      !MessageHTMLHiddenStylePatterns.isPreCleanHidden(nonVisibilityDeclarations),
      !MessageHTMLHiddenStylePatterns.isPresentationHidden(nonVisibilityDeclarations, in: element),
      !MessageHTMLHiddenStylePatterns.isReadableHidden(nonVisibilityDeclarations)
    else { return false }

    var ancestor = element.parent()
    while let current = ancestor, current !== hiddenAncestor {
      let declarations = MessageHTMLHiddenStylePatterns.declarations(in: try current.attr("style"))
      let nonVisibilityDeclarations = declarations.filter { $0.property != "visibility" }
      guard !current.hasAttr("hidden"),
        !MessageHTMLHiddenStylePatterns.isPreCleanHidden(nonVisibilityDeclarations),
        !MessageHTMLHiddenStylePatterns.isPresentationHidden(
          nonVisibilityDeclarations, in: current),
        !MessageHTMLHiddenStylePatterns.isReadableHidden(nonVisibilityDeclarations)
      else { return false }
      let visibility = MessageHTMLHiddenStylePatterns.effectiveValue(
        "visibility",
        in: declarations,
        where: MessageHTMLHiddenStylePatterns.isVisibilityValue
      )
      if ["initial", "visible"].contains(visibility) { return false }
      ancestor = current.parent()
    }
    return true
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

private final class OffCanvasRemoteImageMarkerVisitor: NodeVisitor {
  private var hiddenByDepth: [Bool] = []
  private var precedingFlowPixelsByParent: [ObjectIdentifier: Double] = [:]
  private var flowContributionByElement: [ObjectIdentifier: Double] = [:]
  private var parentsWithIndeterminateFlow: Set<ObjectIdentifier> = []
  private var elementsWithIndeterminateFlow: Set<ObjectIdentifier> = []

  func head(_ node: Node, _ depth: Int) throws {
    guard let element = node as? Element else { return }
    if hiddenByDepth.count > depth {
      hiddenByDepth.removeSubrange(depth...)
    }
    let parentIsHidden = depth > 0 && hiddenByDepth[depth - 1]
    let declarations = MessageHTMLHiddenStylePatterns.declarations(
      in: try element.attr("style")
    )
    let parentKey = element.parent().map(ObjectIdentifier.init)
    let precedingFlowPixels: Double? =
      if let parentKey {
        parentsWithIndeterminateFlow.contains(parentKey)
          ? nil
          : precedingFlowPixelsByParent[parentKey, default: 0]
      } else {
        0
      }
    let isHidden =
      parentIsHidden
      || MessageHTMLHiddenStylePatterns.isOffCanvasHidden(
        declarations,
        in: element,
        precedingFlowPixels: precedingFlowPixels
      )
    hiddenByDepth.append(isHidden)
    let elementKey = ObjectIdentifier(element)
    if let contribution = MessageHTMLHiddenStylePatterns.precedingFlowHeightPixels(
      in: declarations,
      for: element
    ) {
      flowContributionByElement[elementKey] = contribution
    } else {
      elementsWithIndeterminateFlow.insert(elementKey)
    }
    if isHidden && element.hasAttr(RemoteMessageContentMarkup.attribute) {
      try element.removeAttr(RemoteMessageContentMarkup.attribute)
    }
  }

  func tail(_ node: Node, _: Int) throws {
    guard let element = node as? Element, let parent = element.parent() else { return }
    let elementKey = ObjectIdentifier(element)
    let parentKey = ObjectIdentifier(parent)
    let contribution = flowContributionByElement.removeValue(forKey: elementKey) ?? 0
    if elementsWithIndeterminateFlow.remove(elementKey) != nil {
      parentsWithIndeterminateFlow.insert(parentKey)
    } else if !parentsWithIndeterminateFlow.contains(parentKey) {
      precedingFlowPixelsByParent[parentKey, default: 0] += contribution
    }
  }
}

private final class SourceContentVisitor: NodeVisitor {
  private let cancellationCheck: () throws -> Void
  private var hiddenByDepth: [Bool] = []
  private var nonRenderingByDepth: [Bool] = []
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
    let parentIsNonRendering = depth > 0 && nonRenderingByDepth[depth - 1]
    if let element = node as? Element {
      if hiddenByDepth.count > depth {
        hiddenByDepth.removeSubrange(depth...)
        nonRenderingByDepth.removeSubrange(depth...)
      }
      let style = try element.attr("style")
      let declarations = MessageHTMLHiddenStylePatterns.declarations(in: style)
      let isHidden =
        parentIsHidden
        || element.hasAttr("hidden")
        || MessageHTMLHiddenStylePatterns.isPreCleanHidden(declarations)
        || MessageHTMLHiddenStylePatterns.isReadableHidden(declarations)
      hiddenByDepth.append(isHidden)
      nonRenderingByDepth.append(
        parentIsNonRendering || ["script", "style"].contains(element.tagName())
      )
    } else if let textNode = node as? TextNode,
      !parentIsNonRendering,
      MessageHTMLSanitizer.hasReadableText(textNode.getWholeText())
    {
      hasText = true
      hasExplicitlyHiddenText = hasExplicitlyHiddenText || parentIsHidden
    }
  }

  func tail(_: Node, _: Int) throws {}
}
