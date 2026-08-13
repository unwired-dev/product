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

  private static let forwardedWrapperTokens: Set<String> = [
    "gmail_quote", "moz-forward-container",
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
      && isReplyAttribution(element.ownText())
    {
      guard !element.children().isEmpty() else {
        try removeElementAndFollowingSiblings(
          element,
          preserving: protectedReplyContainers
        )
        continue
      }
      try removeDirectAttributionAndFollowingSiblings(from: element)
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

  private static func removeDirectAttributionAndFollowingSiblings(from element: Element) throws {
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

  private static func shouldRemoveQuotedElement(
    _ element: Element,
    tokens: Set<String>,
    identifier: String
  ) throws -> Bool {
    guard !tokens.isDisjoint(with: quotedReplyTokens) || identifier == "divrplyfwdmsg" else {
      return false
    }
    if tokens.isDisjoint(with: forwardedWrapperTokens) {
      return true
    }
    return try containsReplyAttribution(in: element)
  }

  private static func containsReplyAttribution(in element: Element) throws -> Bool {
    if isReplyAttribution(element.ownText()) {
      return true
    }
    for descendant in try element.select("*")
    where isReplyAttribution(descendant.ownText()) {
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
      if isReplyAttribution(text) {
        try candidate.remove()
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

  private static func isReplyAttribution(_ text: String) -> Bool {
    let normalized =
      text
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
      .lowercased()
    return normalized.hasPrefix("on ") && normalized.hasSuffix(" wrote:")
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
        let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return false }
        guard line.lowercased().hasPrefix("on ") else { return false }
        var attribution = ""
        for continuationIndex in index..<min(index + 4, lines.endIndex) {
          let continuation = lines[continuationIndex]
            .trimmingCharacters(in: .whitespacesAndNewlines)
          if continuation.hasPrefix(">") { return false }
          attribution += attribution.isEmpty ? continuation : " \(continuation)"
          if attribution.lowercased().hasSuffix(" wrote:") { return true }
        }
        return false
      }),
      lines[..<quoteStart].contains(where: {
        !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      })
    else {
      return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return lines[..<quoteStart]
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
