import Foundation
import SwiftSoup

// swiftlint:disable file_length

enum CSSLengthValuePolicy {
  static let initialFontSizePixels = 16.0
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
    value.range(
      of: #"^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:%)?$"#,
      options: .regularExpression
    ) != nil || simpleCalculatedOpacity(value) != nil || isCSSWideKeyword(value)
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
      return isCSSWideKeyword(value) || isCSSFunctionValue(value)
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
      let zeroLengthUnits = Set([
        "", "%", "ch", "cm", "em", "ex", "in", "mm", "pc", "pt", "px", "q", "rem", "vh",
        "vmax", "vmin", "vw",
      ])
      guard term.unit == "px" || (term.number == 0 && zeroLengthUnits.contains(term.unit))
      else { return nil }
      if term.unit == "px" { total += term.sign * term.number }
    }
    return total
  }

  private static func constantCalculatedPixelLengthValue(_ value: String) -> Double? {
    if let value = simpleCalculatedPixelLengthValue(value) { return value }
    let normalized = value.lowercased()
    guard let openingParenthesis = normalized.firstIndex(of: "("), normalized.hasSuffix(")")
    else { return nil }
    let function = String(normalized[..<openingParenthesis])
    guard ["clamp", "max", "min"].contains(function) else { return nil }
    let argumentsStart = normalized.index(after: openingParenthesis)
    let argumentsEnd = normalized.index(before: normalized.endIndex)
    let arguments = normalized[argumentsStart..<argumentsEnd].split(
      separator: ",",
      omittingEmptySubsequences: false
    )
    var values: [Double] = []
    for argument in arguments {
      let argument = argument.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !argument.isEmpty,
        let value = CSSLengthValuePolicy.absolutePixelLengthValue(argument)
          ?? simpleCalculatedPixelLengthValue(argument)
      else { return nil }
      values.append(value)
    }
    switch function {
    case "min": return values.min()
    case "max": return values.max()
    default:
      guard values.count == 3 else { return nil }
      return Swift.max(values[0], Swift.min(values[1], values[2]))
    }
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
    if let calculatedValue = pixelLengthValue(value) {
      return calculatedValue <= -100
    }
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
    guard let terms = simpleCalculatedTerms(value) else { return nil }
    guard terms.allSatisfy({ $0.unit.isEmpty || $0.unit == "%" }) else { return nil }
    return terms.reduce(0) { total, term in
      total + term.sign * (term.unit == "%" ? term.number / 100 : term.number)
    }
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
        let number = Double(String(expression[numberStart..<index]))
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
      return StyleDeclaration(
        property: property,
        value: value.lowercased(),
        isImportant: importantRange != nil
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
    try NodeTraversor(OffCanvasRemoteImageMarkerVisitor()).traverse(document)
  }

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
        (visibility == "hidden" || visibility == "collapse")
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

  func head(_ node: Node, _ depth: Int) throws {
    guard let element = node as? Element else { return }
    if hiddenByDepth.count > depth {
      hiddenByDepth.removeSubrange(depth...)
    }
    let parentIsHidden = depth > 0 && hiddenByDepth[depth - 1]
    let declarations = MessageHTMLHiddenStylePatterns.declarations(
      in: try element.attr("style")
    )
    let isHidden = parentIsHidden || MessageHTMLHiddenStylePatterns.isOffCanvasHidden(declarations)
    hiddenByDepth.append(isHidden)
    if isHidden && element.hasAttr(RemoteMessageContentMarkup.attribute) {
      try element.removeAttr(RemoteMessageContentMarkup.attribute)
    }
  }

  func tail(_: Node, _: Int) throws {}
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
