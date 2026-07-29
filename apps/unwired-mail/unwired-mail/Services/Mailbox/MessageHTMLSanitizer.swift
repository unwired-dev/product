import Foundation
import SwiftSoup

struct SanitizedMessageHTML: Equatable, Sendable {
  let bodyHTML: String
  let documentHTML: String
}

enum MessageHTMLSanitizer {
  static func sanitize(_ html: String) throws -> SanitizedMessageHTML? {
    guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

    let bodyHTML =
      try SwiftSoup.clean(html, "", allowlist())
      ?? ""
    let readableDocument = try SwiftSoup.parseBodyFragment(bodyHTML)
    let hiddenStylePattern =
      #"(?:^|;)\s*(?:display\s*:\s*none|"#
      + #"(?:font-size|height|width|line-height)\s*:\s*(?:0+(?:\.0*)?|\.0+)"#
      + #"(?:[a-z%]+)?)(?:\s*!important)?\s*(?:;|$)"#
    for element in try readableDocument.select("[style]") {
      let style = try element.attr("style")
      if style.range(
        of: hiddenStylePattern,
        options: [.regularExpression, .caseInsensitive]
      ) != nil {
        try element.remove()
      }
    }
    let readableText = try readableDocument.text()
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !readableText.isEmpty else { return nil }

    return SanitizedMessageHTML(
      bodyHTML: bodyHTML,
      documentHTML: document(bodyHTML: bodyHTML)
    )
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
      .addAttributes("img", "alt", "height", "width")
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
      .urlWhitespace(.strict)
      .addEnforcedAttribute("a", "rel", "noreferrer noopener")
      .addCSSProperties(
        ":all",
        "background-color", "border", "border-bottom", "border-bottom-color",
        "border-bottom-style", "border-bottom-width", "border-collapse", "border-color",
        "border-left", "border-left-color", "border-left-style", "border-left-width",
        "border-right", "border-right-color", "border-right-style", "border-right-width",
        "border-spacing", "border-style", "border-top", "border-top-color",
        "border-top-style", "border-top-width", "border-width", "color", "display",
        "font-family", "font-size", "font-style", "font-weight", "height", "letter-spacing",
        "line-height", "margin", "margin-bottom", "margin-left", "margin-right", "margin-top",
        "max-width", "min-width", "padding", "padding-bottom", "padding-left",
        "padding-right", "padding-top", "text-align", "text-decoration", "text-indent",
        "text-transform", "vertical-align", "white-space", "width", "word-break", "word-wrap"
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
        default-src 'none'; img-src 'none'; media-src 'none'; style-src 'unsafe-inline';
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

enum MessageHTMLPresentation: Equatable, Sendable {
  case html(SanitizedMessageHTML)
  case plainText(String)

  static func resolve(
    body: MailboxMessageBody,
    renderingFailed: Bool = false,
    sanitizer: (String) throws -> SanitizedMessageHTML? = MessageHTMLSanitizer.sanitize
  ) -> Self {
    guard !renderingFailed, let html = body.html,
      let sanitizedHTML = try? sanitizer(html)
    else {
      return .plainText(body.text)
    }
    return .html(sanitizedHTML)
  }

  static func prepare(
    body: MailboxMessageBody,
    sanitizer: @escaping @Sendable (String) throws -> SanitizedMessageHTML? =
      { try MessageHTMLSanitizer.sanitize($0) }
  ) async -> Self {
    await Task.detached(priority: .userInitiated) {
      resolve(body: body, sanitizer: sanitizer)
    }.value
  }
}
