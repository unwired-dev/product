import Foundation
import SwiftSoup

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
        || style.range(
          of: MessageHTMLHiddenStylePatterns.readable,
          options: [.regularExpression, .caseInsensitive]
        ) != nil
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
