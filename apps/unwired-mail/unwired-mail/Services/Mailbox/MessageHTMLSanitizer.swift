import Foundation
import SwiftSoup

struct SanitizedMessageHTML: Equatable, Sendable {
  let documentHTML: String
}

enum MessageHTMLSanitizer {
  static func sanitize(
    _ html: String,
    cancellationCheck: () throws -> Void = { try Task.checkCancellation() }
  ) throws -> SanitizedMessageHTML? {
    guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

    let bodyHTML =
      try SwiftSoup.clean(html, "", allowlist())
      ?? ""
    try cancellationCheck()
    let presentationDocument = try SwiftSoup.parseBodyFragment(bodyHTML)
    let readableDocument = try SwiftSoup.parseBodyFragment(bodyHTML)
    try cancellationCheck()
    let hiddenStylePattern =
      #"(?:^|;)\s*(?:display\s*:\s*none|"#
      + #"(?:font-size|height|width|line-height)\s*:\s*(?:0+(?:\.0*)?|\.0+)"#
      + #"(?:[a-z%]+)?|(?:text-indent|margin-(?:left|right|top))\s*:\s*-"#
      + #"(?:[1-9]\d*(?:\.\d+)?|"#
      + #"0*\.\d*[1-9]\d*)(?:[a-z%]+)?|"#
      + #"margin\s*:\s*[^;]*-(?:[1-9]\d*(?:\.\d+)?|"#
      + #"0*\.\d*[1-9]\d*)(?:[a-z%]+)?[^;]*)"#
      + #"(?:\s*!important)?\s*(?:;|$)"#
    let presentationHiddenStylePattern =
      #"(?:^|;)\s*(?:display\s*:\s*none|"#
      + #"(?:height|width)\s*:\s*(?:0+(?:\.0*)?|\.0+)"#
      + #"(?:[a-z%]+)?)"#
      + #"(?:\s*!important)?\s*(?:;|$)"#
    try removeElements(matching: hiddenStylePattern, from: readableDocument)
    try removeElements(matching: presentationHiddenStylePattern, from: presentationDocument)
    let ignoredReadableScalars =
      CharacterSet.whitespacesAndNewlines
      .union(.controlCharacters)
      .union(.nonBaseCharacters)
    let hasReadableText = try readableDocument.text().unicodeScalars.contains { scalar in
      !ignoredReadableScalars.contains(scalar)
        && scalar.properties.generalCategory != .format
    }
    let hasInlineImage =
      !referencedInlineImageContentIDs(in: try presentationDocument.outerHtml()).isEmpty
    guard hasReadableText || hasInlineImage else { return nil }

    return SanitizedMessageHTML(
      documentHTML: document(bodyHTML: try presentationDocument.body()?.html() ?? "")
    )
  }

  private static func removeElements(matching pattern: String, from document: Document) throws {
    for element in try document.select("[style]") {
      let style = try element.attr("style")
      if style.range(
        of: pattern,
        options: [.regularExpression, .caseInsensitive]
      ) != nil {
        try element.remove()
      }
    }
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
    guard let document = try? SwiftSoup.parse(html),
      let imageElements = try? document.select("img[src]")
    else {
      return []
    }
    var seenContentIDs: Set<String> = []
    return imageElements.compactMap { element in
      guard !hasZeroDimension(element),
        let source = try? element.attr("src"),
        source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("cid:"),
        let contentID = normalizedContentID(source, decodesPercentEscapes: true),
        seenContentIDs.insert(contentID).inserted
      else {
        return nil
      }
      return contentID
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

  private static func hasZeroDimension(_ element: Element) -> Bool {
    for attribute in ["width", "height"] {
      guard let value = try? element.attr(attribute), !value.isEmpty else { continue }
      if value.trimmingCharacters(in: .whitespacesAndNewlines).range(
        of: #"^(?:0+(?:\.0*)?|\.0+)(?:[a-z%]+)?$"#,
        options: [.regularExpression, .caseInsensitive]
      ) != nil {
        return true
      }
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
      .addAttributes(":all", "dir", "lang", "style", "title")
      .addAttributes("a", "href")
      .addAttributes("blockquote", "cite")
      .addAttributes("col", "align", "span", "valign", "width")
      .addAttributes("colgroup", "align", "span", "valign", "width")
      .addAttributes("img", "alt", "height", "src", "width")
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
        "margin", "margin-bottom", "margin-left", "margin-right", "margin-top", "max-width",
        "min-width", "padding", "padding-bottom", "padding-left", "padding-right", "padding-top",
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
      _ = try? element.attr(
        "src",
        "data:\(image.mimeType);base64,\(image.data.base64EncodedString())"
      )
    }
    guard let resolvedHTML = try? document.outerHtml() else {
      return html
    }
    return SanitizedMessageHTML(documentHTML: resolvedHTML)
  }
}

enum MessageHTMLPresentation: Equatable, Sendable {
  case html(SanitizedMessageHTML)
  case plainText(String)

  static func resolve(
    body: MailboxMessageBody,
    renderingFailed: Bool = false,
    sanitizer: (String) throws -> SanitizedMessageHTML? =
      { try MessageHTMLSanitizer.sanitize($0) }
  ) -> Self {
    guard !renderingFailed, let html = body.html,
      let sanitizedHTML = try? sanitizer(html)
    else {
      return .plainText(body.text)
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
    sanitizer: @escaping @Sendable (String) throws -> SanitizedMessageHTML? =
      { try MessageHTMLSanitizer.sanitize($0) }
  ) async throws -> Self {
    let preparation = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      let presentation = resolve(body: body, sanitizer: sanitizer)
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
