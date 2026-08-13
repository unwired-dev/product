import Foundation
import SwiftSoup

// swiftlint:disable file_length

struct SanitizedMessageHTML: Equatable, Sendable {
  let documentHTML: String
  let remoteImageReferences: [RemoteMessageImageReference]

  init(
    documentHTML: String,
    remoteImageReferences: [RemoteMessageImageReference] = []
  ) {
    self.documentHTML = documentHTML
    self.remoteImageReferences = remoteImageReferences
  }
}

enum MessageHTMLSanitizer {
  static func sanitize(
    _ html: String,
    removesQuotedReplies: Bool = false,
    cancellationCheck: () throws -> Void = { try Task.checkCancellation() }
  ) throws -> SanitizedMessageHTML? {
    guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

    let sourceDocument = try SwiftSoup.parseBodyFragment(html)
    try removeKnownPreheaders(from: sourceDocument)
    if removesQuotedReplies {
      try removeQuotedReplies(from: sourceDocument)
    }
    let sourceContent = try sourceContent(
      in: sourceDocument,
      cancellationCheck: cancellationCheck
    )
    try removeHiddenElements(from: [sourceDocument])
    var remoteImageReferences = try RemoteMessageContentMarkup.recordReferences(
      in: sourceDocument
    )
    try removePreCleanHiddenElements(from: sourceDocument, cancellationCheck: cancellationCheck)
    let documents = try cleanedDocuments(
      from: sourceDocument,
      cancellationCheck: cancellationCheck
    )
    let presentationDocument = documents.presentation
    let readableDocument = documents.readable
    try removeHiddenElements(from: [presentationDocument, readableDocument])
    try removeReadableHiddenElements(from: readableDocument)
    try removePresentationHiddenElements(from: presentationDocument)
    try removeOffCanvasRemoteImageMarkers(from: presentationDocument)
    remoteImageReferences = try RemoteMessageContentMarkup.retainedReferences(
      remoteImageReferences,
      in: presentationDocument
    )
    guard
      try hasRenderableContent(
        presentationDocument: presentationDocument,
        readableDocument: readableDocument,
        hasRemoteImageOnlyContent: (!sourceContent.hasText || sourceContent.hasExplicitlyHiddenText)
          && !remoteImageReferences.isEmpty
      )
    else { return nil }

    return SanitizedMessageHTML(
      documentHTML: document(bodyHTML: try presentationDocument.body()?.html() ?? ""),
      remoteImageReferences: remoteImageReferences
    )
  }
}

extension MessageHTMLSanitizer {
  private static let preheaderTokens: Set<String> = [
    "email-preheader", "email_preview", "emailpreview", "mc-preview-text", "mcnpreviewtext",
    "pre-header", "preheader", "preview-text", "preview_text",
  ]

  private static let quotedReplyTokens: Set<String> = [
    "gmail_attr", "gmail_quote", "moz-cite-prefix", "moz-forward-container",
    "protonmail_quote", "yahoo_quoted", "zmail_extra",
  ]

  private static let replyAttributionTokens: Set<String> = [
    "gmail_attr", "moz-cite-prefix",
  ]

  private static let forwardedWrapperTokens: Set<String> = [
    "gmail_quote", "moz-forward-container",
  ]

  private static let replyDateWords: Set<String> = [
    "apr", "april", "aug", "august", "dec", "december", "feb", "february", "fri",
    "friday", "jan", "january", "jul", "july", "jun", "june", "mar", "march", "may",
    "mon", "monday", "nov", "november", "oct", "october", "sat", "saturday", "sep",
    "sept", "september", "sun", "sunday", "thu", "thursday", "tue", "tues", "tuesday",
    "wed", "wednesday",
  ]

  private static let transparentReplyBoundaryTags: Set<String> = [
    "a", "b", "em", "font", "i", "small", "span", "strong", "u",
  ]

  private static func removeKnownPreheaders(from document: Document) throws {
    for element in try document.select("title") {
      try element.remove()
    }
    for element in try document.select("[class], [id]") {
      guard !elementTokens(element).isDisjoint(with: preheaderTokens) else { continue }
      try element.remove()
    }
  }

  private static func removeQuotedReplies(from document: Document) throws {
    let protectedReplyContainers = try protectedReplyContainers(in: document)
    for element in try document.select("[class], [id]") {
      let tokens = elementTokens(element)
      let identifier = try element.attr("id").lowercased()
      guard try shouldRemoveQuotedElement(element, tokens: tokens, identifier: identifier) else {
        continue
      }
      if identifier == "divrplyfwdmsg" {
        var sibling = try element.nextElementSibling()
        while let quotedSibling = sibling {
          sibling = try quotedSibling.nextElementSibling()
          try quotedSibling.remove()
        }
      }
      try element.remove()
    }
    for element in try document.select("blockquote") {
      guard try removeReplyAttribution(before: element) else { continue }
      try element.remove()
    }
    for element in try document.select("*").reversed()
    where element.parent() != nil
      && element.tagName().lowercased() != "body"
      && isReplyAttributionElement(element)
    {
      guard !element.children().isEmpty() else {
        guard try hasFollowingQuotedReplyBoundary(after: element) else { continue }
        try removeElementAndFollowingSiblings(
          element,
          preserving: protectedReplyContainers
        )
        continue
      }
      try removeDirectAttributionAndFollowingSiblings(
        from: element,
        preserving: protectedReplyContainers
      )
    }
    try removeBodyReplyAttributions(
      from: document,
      preserving: protectedReplyContainers
    )
  }

  private static func removeElementAndFollowingSiblings(
    _ element: Element,
    preserving protectedReplyContainers: [Element]
  ) throws {
    var sibling = try element.nextElementSibling()
    while let quotedSibling = sibling {
      guard !protectedReplyContainers.contains(where: { $0 === quotedSibling }) else { break }
      sibling = try quotedSibling.nextElementSibling()
      try quotedSibling.remove()
    }
    try element.remove()
  }

  private static func protectedReplyContainers(in document: Document) throws -> [Element] {
    try document.select("*").filter {
      try hasLeadingContentBeforeDirectReplyAttribution(in: $0)
    }
  }

  private static func removeBodyReplyAttributions(
    from document: Document,
    preserving protectedReplyContainers: [Element]
  ) throws {
    for attribution in document.body()?.textNodes().reversed() ?? []
    where isReplyAttribution(attribution.getWholeText()) {
      guard try hasFollowingQuotedReplyBoundary(after: attribution) else { continue }
      var sibling = attribution.nextSibling()
      while let quotedSibling = sibling {
        if let element = quotedSibling as? Element,
          protectedReplyContainers.contains(where: { $0 === element })
        {
          break
        }
        sibling = quotedSibling.nextSibling()
        try quotedSibling.remove()
      }
      try attribution.remove()
    }
  }

  private static func hasLeadingContentBeforeDirectReplyAttribution(
    in element: Element
  ) throws -> Bool {
    var hasLeadingContent = false
    for child in element.getChildNodes() {
      let text: String
      if let textNode = child as? TextNode {
        text = textNode.getWholeText()
      } else if let childElement = child as? Element {
        text = try childElement.text()
      } else {
        continue
      }
      if isReplyAttribution(text) {
        return hasLeadingContent
      }
      if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        hasLeadingContent = true
      }
    }
    return false
  }

  private static func removeDirectAttributionAndFollowingSiblings(
    from element: Element,
    preserving protectedReplyContainers: [Element]
  ) throws {
    for attribution in element.textNodes().reversed()
    where isReplyAttribution(attribution.getWholeText()) {
      let hasInternalBoundary = try hasFollowingQuotedReplyBoundary(after: attribution)
      let hasExternalBoundary =
        if hasInternalBoundary {
          false
        } else {
          try hasFollowingQuotedReplyBoundary(after: element)
        }
      guard hasInternalBoundary || hasExternalBoundary else { continue }
      var sibling = attribution.nextSibling()
      while let quotedSibling = sibling {
        sibling = quotedSibling.nextSibling()
        try quotedSibling.remove()
      }
      try attribution.remove()
      if hasExternalBoundary {
        var externalSibling = try element.nextElementSibling()
        while let quotedSibling = externalSibling {
          guard !protectedReplyContainers.contains(where: { $0 === quotedSibling }) else { break }
          externalSibling = try quotedSibling.nextElementSibling()
          try quotedSibling.remove()
        }
      }
    }
  }

  private static func shouldRemoveQuotedElement(
    _ element: Element,
    tokens: Set<String>,
    identifier: String
  ) throws -> Bool {
    guard !tokens.isDisjoint(with: quotedReplyTokens) || identifier == "divrplyfwdmsg" else {
      return false
    }
    if !tokens.isDisjoint(with: replyAttributionTokens) {
      return false
    }
    if identifier == "divrplyfwdmsg" {
      return try !isForwardedMessageMarker(element)
        && !hasPrecedingForwardedMessageIntent(before: element)
    }
    if try hasLeadingForwardedMessageMarker(in: element) {
      return false
    }
    if tokens.isDisjoint(with: forwardedWrapperTokens) {
      return true
    }
    return try containsReplyAttribution(in: element)
  }

  private static func containsReplyAttribution(in element: Element) throws -> Bool {
    if isReplyAttributionElement(element) {
      return true
    }
    for descendant in try element.select("*")
    where isReplyAttributionElement(descendant) {
      return true
    }
    return false
  }

  private static func removeReplyAttribution(before quotedReply: Element) throws -> Bool {
    var sibling = quotedReply.previousSibling()
    var separators: [Node] = []
    while let candidate = sibling {
      let text: String
      if let textNode = candidate as? TextNode {
        text = textNode.getWholeText()
      } else if let element = candidate as? Element {
        text = try element.text()
      } else {
        return false
      }
      let candidateElement = candidate as? Element
      let nestedAttribution = try candidateElement.flatMap {
        try trailingNestedReplyAttribution(in: $0)
      }
      if isReplyAttribution(text)
        || candidateElement.map(isReplyAttributionElement) == true
        || nestedAttribution != nil
      {
        if let nestedAttribution {
          try nestedAttribution.remove()
        } else if let element = candidateElement,
          try hasLeadingContentBeforeDirectReplyAttribution(in: element)
        {
          try removeDirectAttributionAndFollowingSiblingsWithin(element)
        } else {
          try candidate.remove()
        }
        for separator in separators {
          try separator.remove()
        }
        return true
      }
      let isBreak = (candidate as? Element)?.tagName().lowercased() == "br"
      guard isBreak || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return false
      }
      separators.append(candidate)
      sibling = candidate.previousSibling()
    }
    return false
  }

  private enum ReplyWrapperContent {
    case attribution(Element)
    case content
  }

  private static func trailingNestedReplyAttribution(in element: Element) throws -> Element? {
    let content = try element.getChildNodes().flatMap(replyWrapperContent)
    let attributions = content.enumerated().compactMap { index, item in
      if case .attribution(let attribution) = item {
        return (index, attribution)
      }
      return nil
    }
    guard attributions.count == 1, let match = attributions.first else { return nil }
    guard
      content[..<match.0].contains(where: {
        if case .content = $0 { return true }
        return false
      })
    else { return nil }
    guard content.index(after: match.0) == content.endIndex else { return nil }
    return match.1
  }

  private static func replyWrapperContent(in node: Node) throws -> [ReplyWrapperContent] {
    if let textNode = node as? TextNode {
      return textNode.getWholeText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? [] : [.content]
    }
    guard let element = node as? Element else { return [] }
    if isReplyAttributionElement(element) {
      return [.attribution(element)]
    }
    if element.tagName().lowercased() == "br" {
      return []
    }
    return try element.getChildNodes().flatMap(replyWrapperContent)
  }

  private static func removeDirectAttributionAndFollowingSiblingsWithin(
    _ element: Element
  ) throws {
    for attribution in element.textNodes().reversed()
    where isReplyAttribution(attribution.getWholeText()) {
      var sibling = attribution.nextSibling()
      while let quotedSibling = sibling {
        sibling = quotedSibling.nextSibling()
        try quotedSibling.remove()
      }
      try attribution.remove()
    }
  }

  fileprivate static func isReplyAttribution(_ text: String) -> Bool {
    let normalized =
      text
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
      .lowercased()
    guard normalized.hasPrefix("on "), normalized.hasSuffix(" wrote:") else {
      return false
    }
    let attribution =
      normalized
      .dropFirst(3)
      .dropLast(" wrote:".count)
      .trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
    let segments = attribution.split(separator: ",", omittingEmptySubsequences: true)
    guard segments.count >= 2 else { return false }
    let context = segments.dropLast().joined(separator: ",")
    let sender = segments[segments.index(before: segments.endIndex)]
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard hasReplyDateContext(context) || context.contains("@") || sender.contains("@") else {
      return false
    }
    return !["he", "i", "she", "they", "we", "you"].contains(sender)
  }

  private static func isReplyAttributionElement(_ element: Element) -> Bool {
    let text = element.ownText()
    return
      (!elementTokens(element).isDisjoint(with: replyAttributionTokens)
      && !isForwardedMessageText(text))
      || isReplyAttribution(text)
  }

  private static func hasFollowingQuotedReplyBoundary(after node: Node) throws -> Bool {
    var sibling = node.nextSibling()
    while let candidate = sibling {
      sibling = candidate.nextSibling()
      if let textNode = candidate as? TextNode {
        let text = textNode.getWholeText().trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { continue }
        return text.hasPrefix(">")
      }
      guard let element = candidate as? Element else { return false }
      let tagName = element.tagName().lowercased()
      if tagName == "br" {
        continue
      }
      let text = try element.text().trimmingCharacters(in: .whitespacesAndNewlines)
      if text.isEmpty {
        continue
      }
      if tagName == "blockquote"
        || tagName == "div"
        || !elementTokens(element).isDisjoint(with: quotedReplyTokens)
        || text.hasPrefix(">")
      {
        return true
      }
      if transparentReplyBoundaryTags.contains(tagName) {
        continue
      }
      return false
    }
    return false
  }

  private static func isForwardedMessageMarker(_ element: Element) throws -> Bool {
    isForwardedMessageText(try element.text())
  }

  private static func hasPrecedingForwardedMessageIntent(before element: Element) throws -> Bool {
    var sibling = element.previousSibling()
    while let candidate = sibling {
      sibling = candidate.previousSibling()
      if let textNode = candidate as? TextNode {
        let text = textNode.getWholeText().trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { continue }
        return isForwardedMessageText(text)
      }
      guard let candidateElement = candidate as? Element else { return false }
      if candidateElement.tagName().lowercased() == "br" { continue }
      let text = try candidateElement.text().trimmingCharacters(in: .whitespacesAndNewlines)
      if text.isEmpty { continue }
      return isForwardedMessageText(text)
    }
    return false
  }

  private static func hasLeadingForwardedMessageMarker(in element: Element) throws -> Bool {
    if isForwardedMessageText(element.ownText()) {
      return true
    }
    for descendant in try element.select("*") {
      let text = descendant.ownText().trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { continue }
      return isForwardedMessageText(text)
    }
    return false
  }

  private static func isForwardedMessageText(_ text: String) -> Bool {
    let normalized =
      text
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
      .lowercased()
    return normalized.contains("forwarded message")
      || normalized.contains("original message")
      || normalized.range(
        of: #"subject:\s*(?:fw|fwd):"#,
        options: .regularExpression
      ) != nil
  }

  private static func hasReplyDateContext(_ text: String) -> Bool {
    let words = Set(
      text.lowercased()
        .split(whereSeparator: { !$0.isLetter })
        .map(String.init)
    )
    if !words.isDisjoint(with: replyDateWords) {
      return true
    }
    return text.range(
      of: #"\b\d{1,4}[-/.]\d{1,2}(?:[-/.]\d{1,4})?\b"#,
      options: .regularExpression
    ) != nil
  }

  private static func elementTokens(_ element: Element) -> Set<String> {
    let classes = (try? element.attr("class")) ?? ""
    let identifier = (try? element.attr("id")) ?? ""
    return Set(
      "\(classes) \(identifier)"
        .lowercased()
        .split(whereSeparator: { $0.isWhitespace })
        .map(String.init)
    )
  }

  private static func cleanedDocuments(
    from sourceDocument: Document,
    cancellationCheck: () throws -> Void
  ) throws -> (presentation: Document, readable: Document) {
    let sourceHTML = try sourceDocument.body()?.html() ?? ""
    let bodyHTML = try SwiftSoup.clean(sourceHTML, "", allowlist()) ?? ""
    try cancellationCheck()
    let presentationDocument = try SwiftSoup.parseBodyFragment(bodyHTML)
    let readableDocument = try SwiftSoup.parseBodyFragment(bodyHTML)
    try cancellationCheck()
    return (presentationDocument, readableDocument)
  }

  private static func removeReadableHiddenElements(from document: Document) throws {
    for element in try document.select("[style]") {
      let declarations = MessageHTMLHiddenStylePatterns.declarations(
        in: try element.attr("style")
      )
      guard MessageHTMLHiddenStylePatterns.isReadableHidden(declarations) else {
        continue
      }
      try element.remove()
    }
  }

  private static func removePresentationHiddenElements(from document: Document) throws {
    for element in try document.select("[style]") {
      let declarations = MessageHTMLHiddenStylePatterns.declarations(
        in: try element.attr("style")
      )
      guard MessageHTMLHiddenStylePatterns.isPresentationHidden(declarations, in: element) else {
        continue
      }
      try element.remove()
    }
  }

  private static func removeHiddenElements(from documents: [Document]) throws {
    for document in documents {
      for element in try document.select("[hidden]") {
        try element.remove()
      }
    }
  }

  private static func hasRenderableContent(
    presentationDocument: Document,
    readableDocument: Document,
    hasRemoteImageOnlyContent: Bool
  ) throws -> Bool {
    let hasInlineImage =
      !referencedInlineImageContentIDs(in: try presentationDocument.outerHtml()).isEmpty
    return try hasReadableText(readableDocument.text()) || hasInlineImage
      || hasRemoteImageOnlyContent
  }

  static func normalizedContentID(_ value: String, decodesPercentEscapes: Bool = false) -> String? {
    let decoded = decodesPercentEscapes ? (value.removingPercentEncoding ?? value) : value
    var normalized = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized.lowercased().hasPrefix("cid:") {
      normalized.removeFirst(4)
    }
    normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized.hasPrefix("<"), normalized.hasSuffix(">") {
      normalized.removeFirst()
      normalized.removeLast()
    }
    normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized.isEmpty ? nil : normalized
  }

  static func referencedInlineImageContentIDs(in html: String) -> [String] {
    var seenContentIDs: Set<String> = []
    return referencedInlineImageContentIDOccurrences(in: html).filter {
      seenContentIDs.insert($0).inserted
    }
  }

  static func referencedInlineImageContentIDOccurrences(in html: String) -> [String] {
    guard let document = try? SwiftSoup.parse(html),
      let imageElements = try? document.select("img[src]")
    else {
      return []
    }
    return imageElements.compactMap { element in
      guard !hasZeroDimension(element),
        let source = try? element.attr("src"),
        source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("cid:"),
        let contentID = normalizedContentID(source, decodesPercentEscapes: true)
      else {
        return nil
      }
      return contentID
    }
  }

  static func referencedSanitizedInlineImageContentIDOccurrences(
    in html: String
  ) throws -> [String] {
    do {
      guard let sanitizedHTML = try sanitize(html) else { return [] }
      return referencedInlineImageContentIDOccurrences(in: sanitizedHTML.documentHTML)
    } catch let error as CancellationError {
      throw error
    } catch {
      return []
    }
  }

  static func mayReferenceInlineImage(in html: String) -> Bool {
    if html.range(of: "cid:", options: .caseInsensitive) != nil {
      return true
    }
    let encodedCIDPattern =
      #"(?:c|&#(?:0*99|x0*63);?)(?:i|&#(?:0*105|x0*69);?)"#
      + #"(?:d|&#(?:0*100|x0*64);?)(?::|&#(?:0*58|x0*3a);?|&colon;)"#
    return html.range(
      of: encodedCIDPattern,
      options: [.regularExpression, .caseInsensitive]
    ) != nil
  }

  static func hasZeroDimension(_ element: Element) -> Bool {
    let zeroDimensionPattern = #"^[+-]?(?:0+(?:\.0*)?|\.0+)(?:[a-z%]+)?$"#
    for attribute in ["width", "height"] {
      if let styleValue = InlineImageDimensionPolicy.value(attribute, in: element) {
        if styleValue.range(
          of: zeroDimensionPattern,
          options: [.regularExpression, .caseInsensitive]
        ) != nil || InlineImageDimensionPolicy.hasZeroUsedDimension(attribute, in: element),
          !InlineImageDimensionPolicy.hasPositiveMinimum(attribute, in: element)
        {
          return true
        }
        continue
      }
      guard let value = try? element.attr(attribute), !value.isEmpty else { continue }
      if value.trimmingCharacters(in: .whitespacesAndNewlines).range(
        of: zeroDimensionPattern,
        options: [.regularExpression, .caseInsensitive]
      ) != nil, !InlineImageDimensionPolicy.hasPositiveMinimum(attribute, in: element) {
        return true
      }
    }
    for dimension in ["width", "height"]
    where InlineImageDimensionPolicy.value("max-\(dimension)", in: element)?.range(
      of: zeroDimensionPattern,
      options: [.regularExpression, .caseInsensitive]
    ) != nil && !InlineImageDimensionPolicy.hasPositiveMinimum(dimension, in: element) {
      return true
    }
    return false
  }

  private static func allowlist() throws -> Whitelist {
    try Whitelist.none()
      .addTags(
        "a", "b", "blockquote", "br", "caption", "center", "cite", "code", "col",
        "colgroup", "dd", "div", "dl", "dt", "em", "h1", "h2", "h3", "h4", "h5",
        "h6", "hr", "i", "img", "li", "ol", "p", "pre", "q", "s", "small", "span",
        "strike", "strong", "sub", "sup", "table", "tbody", "td", "tfoot", "th",
        "thead", "tr", "u", "ul"
      )
      .addAttributes(":all", "dir", "hidden", "lang", "style", "title")
      .addAttributes("a", "href")
      .addAttributes("blockquote", "cite")
      .addAttributes("col", "align", "span", "valign", "width")
      .addAttributes("colgroup", "align", "span", "valign", "width")
      .addAttributes("img", "alt", "height", "src", "width")
      .addAttributes("img", RemoteMessageContentMarkup.attribute)
      .addAttributes("li", "value")
      .addAttributes("ol", "start", "type")
      .addAttributes("q", "cite")
      .addAttributes(
        "table", "align", "border", "cellpadding", "cellspacing", "role", "summary", "width"
      )
      .addAttributes(
        "td", "abbr", "align", "colspan", "headers", "height", "rowspan", "valign", "width"
      )
      .addAttributes(
        "th", "abbr", "align", "colspan", "headers", "height", "rowspan", "scope", "valign",
        "width"
      )
      .addAttributes("ul", "type")
      .addProtocols("a", "href", "http", "https", "mailto", "tel")
      .addProtocols("blockquote", "cite", "http", "https")
      .addProtocols("q", "cite", "http", "https")
      .addProtocols("img", "src", "cid")
      .urlWhitespace(.strict)
      .addEnforcedAttribute("a", "rel", "noreferrer noopener")
      .addCSSProperties(
        ":all",
        "border", "border-bottom", "border-bottom-color", "border-bottom-style",
        "border-bottom-width", "border-collapse", "border-color",
        "border-left", "border-left-color", "border-left-style", "border-left-width",
        "border-right", "border-right-color", "border-right-style", "border-right-width",
        "border-spacing", "border-style", "border-top", "border-top-color",
        "border-top-style", "border-top-width", "border-width", "display", "font-family",
        "font-size", "font-style", "font-weight", "height", "letter-spacing", "line-height",
        "margin", "margin-bottom", "margin-left", "margin-right", "margin-top", "max-height",
        "max-width", "min-height", "min-width", "padding", "padding-bottom", "padding-left",
        "padding-right", "padding-top",
        "text-align", "text-decoration", "text-indent", "text-transform", "vertical-align",
        "white-space", "width", "word-break", "word-wrap"
      )
  }

  private static func document(bodyHTML: String) -> String {
    """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta http-equiv="Content-Security-Policy" content="
        default-src 'none'; img-src data:; media-src 'none'; style-src 'unsafe-inline';
        font-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none';
        base-uri 'none'; form-action 'none'
      ">
      <style>
        :root { color-scheme: light; }
        html, body {
          background: #fff;
          color: #111;
          font: -apple-system-body;
          margin: 0;
          overflow-wrap: anywhere;
          padding: 0;
        }
        a { color: LinkText; }
        img, table { max-width: 100%; }
        pre { overflow-wrap: anywhere; white-space: pre-wrap; }
      </style>
    </head>
    <body>\(bodyHTML)</body>
    </html>
    """
  }
}

enum MessageHTMLInlineImageResolver {
  private static let maximumEmbeddedImageByteCount = 20 * 1_024 * 1_024

  static func resolve(
    _ html: SanitizedMessageHTML,
    inlineImages: [MailboxMessageInlineImage]
  ) -> SanitizedMessageHTML {
    guard html.documentHTML.range(of: "cid:", options: .caseInsensitive) != nil,
      let document = try? SwiftSoup.parse(html.documentHTML)
    else {
      return html
    }
    let imagesByContentID = Dictionary(
      inlineImages.compactMap { image in
        MessageHTMLSanitizer.normalizedContentID(image.contentID).map { ($0, image) }
      },
      uniquingKeysWith: { first, _ in first }
    )
    guard let imageElements = try? document.select("img[src]") else {
      return html
    }
    var remainingEmbeddedImageByteCount = maximumEmbeddedImageByteCount
    for element in imageElements {
      guard
        let source = try? element.attr("src"),
        let contentID = MessageHTMLSanitizer.normalizedContentID(
          source,
          decodesPercentEscapes: true
        ),
        let image = imagesByContentID[contentID]
      else {
        _ = try? element.removeAttr("src")
        continue
      }
      guard image.data.count <= remainingEmbeddedImageByteCount else {
        _ = try? element.removeAttr("src")
        continue
      }
      remainingEmbeddedImageByteCount -= image.data.count
      _ = try? element.attr(
        "src",
        "data:\(image.mimeType);base64,\(image.data.base64EncodedString())"
      )
    }
    guard let resolvedHTML = try? document.outerHtml() else {
      return html
    }
    return SanitizedMessageHTML(
      documentHTML: resolvedHTML,
      remoteImageReferences: html.remoteImageReferences
    )
  }
}

enum MessageHTMLPresentation: Equatable, Sendable {
  case html(SanitizedMessageHTML)
  case plainText(String)

  static func resolve(
    body: MailboxMessageBody,
    renderingFailed: Bool = false,
    removesQuotedReplies: Bool = false,
    sanitizer: (String, Bool) throws -> SanitizedMessageHTML? =
      { try MessageHTMLSanitizer.sanitize($0, removesQuotedReplies: $1) }
  ) -> Self {
    let presentationText =
      removesQuotedReplies
      ? MessagePlainTextPresentation.withoutQuotedReply(body.text) : body.text
    guard !renderingFailed, let html = body.html,
      let sanitizedHTML = try? sanitizer(html, removesQuotedReplies)
    else {
      return .plainText(presentationText)
    }
    return .html(
      MessageHTMLInlineImageResolver.resolve(
        sanitizedHTML,
        inlineImages: body.inlineImages
      )
    )
  }

  static func prepare(
    body: MailboxMessageBody,
    removesQuotedReplies: Bool = false,
    sanitizer: @escaping @Sendable (String, Bool) throws -> SanitizedMessageHTML? =
      { try MessageHTMLSanitizer.sanitize($0, removesQuotedReplies: $1) }
  ) async throws -> Self {
    let preparation = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      let presentation = resolve(
        body: body,
        removesQuotedReplies: removesQuotedReplies,
        sanitizer: sanitizer
      )
      try Task.checkCancellation()
      return presentation
    }
    let presentation = try await withTaskCancellationHandler {
      try await preparation.value
    } onCancel: {
      preparation.cancel()
    }
    try Task.checkCancellation()
    return presentation
  }
}

enum MessagePlainTextPresentation {
  static func withoutQuotedReply(_ text: String) -> String {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    guard
      let quoteStart = lines.indices.first(where: { index in
        guard let attributionEnd = replyAttributionEnd(in: lines, startingAt: index) else {
          return false
        }
        return lines[(attributionEnd + 1)...].first(where: {
          !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(">") == true
      })
    else {
      return text
    }
    return lines[..<quoteStart]
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func replyAttributionEnd(
    in lines: [Substring],
    startingAt index: Int
  ) -> Int? {
    let firstLine = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
    guard firstLine.lowercased().hasPrefix("on ") else { return nil }
    var attribution = ""
    for continuationIndex in index..<min(index + 4, lines.endIndex) {
      let continuation = lines[continuationIndex]
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if continuation.hasPrefix(">") { return nil }
      attribution += attribution.isEmpty ? continuation : " \(continuation)"
      if MessageHTMLSanitizer.isReplyAttribution(attribution) {
        return continuationIndex
      }
    }
    return nil
  }
}
