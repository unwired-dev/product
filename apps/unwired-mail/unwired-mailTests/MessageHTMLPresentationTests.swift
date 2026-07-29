import WebKit
import XCTest

@testable import unwired_mail

final class MessageHTMLPresentationTests: XCTestCase {
  func testSanitizerPreservesCommonEmailLayoutAndSafeStyles() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <table width="100%" cellpadding="8" cellspacing="0" style="border-collapse: collapse">
          <tr>
            <td align="center" style="color: #123456; background-image: url(https://tracker.test/pixel)">
              <strong>Receipt</strong>
            </td>
          </tr>
        </table>
        """
      )
    )

    XCTAssertTrue(result.bodyHTML.contains("<table"))
    XCTAssertTrue(result.bodyHTML.contains("width=\"100%\""))
    XCTAssertTrue(result.bodyHTML.contains("cellpadding=\"8\""))
    XCTAssertTrue(result.bodyHTML.contains("border-collapse:collapse"))
    XCTAssertTrue(result.bodyHTML.contains("color:#123456"))
    XCTAssertFalse(result.bodyHTML.contains("background-image"))
    XCTAssertTrue(result.bodyHTML.contains("<strong>Receipt</strong>"))
  }

  func testSanitizerRemovesActiveContentUnsafeURLsAndRemoteImageSources() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <meta http-equiv="refresh" content="0; https://attacker.test">
        <script>alert("script")</script>
        <form action="https://attacker.test"><input name="secret"></form>
        <iframe src="https://attacker.test"></iframe>
        <object data="https://attacker.test"></object>
        <p onclick="alert('event')">Safe text</p>
        <a href="javascript:alert('url')">Unsafe link</a>
        <a href="https://example.com/path">Safe link</a>
        <img src="https://tracker.test/pixel" onerror="alert('image')" alt="Receipt" width="1">
        """
      )
    )
    let sanitized = result.bodyHTML.lowercased()

    for forbidden in [
      "<meta", "<script", "<form", "<input", "<iframe", "<object", "onclick",
      "javascript:", "onerror", "tracker.test",
    ] {
      XCTAssertFalse(sanitized.contains(forbidden), "Unexpected active content: \(forbidden)")
    }
    XCTAssertTrue(sanitized.contains("safe text"))
    XCTAssertTrue(sanitized.contains(">unsafe link</a>"))
    XCTAssertTrue(sanitized.contains("href=\"https://example.com/path\""))
    XCTAssertTrue(sanitized.contains("<img"))
    XCTAssertTrue(sanitized.contains("alt=\"receipt\""))
    XCTAssertTrue(sanitized.contains("width=\"1\""))
  }

  func testSanitizerAllowsOnlyExplicitLinkSchemes() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <a href="https://example.com">Web</a>
        <a href="mailto:person@example.com">Mail</a>
        <a href="tel:+420123456789">Phone</a>
        <a href="ftp://example.com/file">FTP</a>
        <a href="/relative">Relative</a>
        """
      )
    )

    XCTAssertTrue(result.bodyHTML.contains("href=\"https://example.com\""))
    XCTAssertTrue(result.bodyHTML.contains("href=\"mailto:person@example.com\""))
    XCTAssertTrue(result.bodyHTML.contains("href=\"tel:+420123456789\""))
    XCTAssertFalse(result.bodyHTML.contains("ftp://"))
    XCTAssertFalse(result.bodyHTML.contains("href=\"/relative\""))
  }

  func testSanitizerHandlesMalformedMarkupAndRejectsEmptyActiveContent() throws {
    let malformed = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize("<table><tr><td><b>Readable")
    )

    XCTAssertTrue(malformed.bodyHTML.contains("<b>Readable</b>"))
    XCTAssertNil(try MessageHTMLSanitizer.sanitize("<script>alert('only active content')</script>"))
    XCTAssertNil(try MessageHTMLSanitizer.sanitize(" \n\t "))
  }

  func testSanitizerRejectsContentOnlyReadableThroughHiddenPreheaderText() throws {
    XCTAssertNil(
      try MessageHTMLSanitizer.sanitize(
        """
        <div style="display: none !important">Hidden preview</div>
        <img src="https://tracker.test/hero.png">
        """
      )
    )
  }

  func testSanitizerRejectsContentOnlyReadableThroughZeroSizedPreheaderText() throws {
    for style in ["font-size: 0", "height: 0px", "width: 0%", "line-height: 0.0em !important"] {
      XCTAssertNil(
        try MessageHTMLSanitizer.sanitize(
          """
          <div style="\(style)">Hidden preview</div>
          <img src="https://tracker.test/hero.png">
          """
        ),
        "Expected \(style) content to be unreadable"
      )
    }
  }

  func testSanitizedDocumentUsesRestrictiveContentSecurityPolicy() throws {
    let result = try XCTUnwrap(MessageHTMLSanitizer.sanitize("<p>Hello</p>"))

    XCTAssertTrue(result.documentHTML.contains("default-src 'none'"))
    XCTAssertTrue(result.documentHTML.contains("img-src 'none'"))
    XCTAssertTrue(result.documentHTML.contains("connect-src 'none'"))
    XCTAssertTrue(result.documentHTML.contains("frame-src 'none'"))
    XCTAssertTrue(result.documentHTML.contains("object-src 'none'"))
    XCTAssertTrue(result.documentHTML.contains("base-uri 'none'"))
    XCTAssertTrue(result.documentHTML.contains("form-action 'none'"))
    XCTAssertTrue(result.documentHTML.contains("<p>Hello</p>"))
  }

  func testSanitizedDocumentUsesANeutralLightCanvasForFixedEmailColors() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(#"<p style="color: #000">Hello</p>"#)
    )

    XCTAssertTrue(result.bodyHTML.contains("color:#000"))
    XCTAssertTrue(result.documentHTML.contains(":root { color-scheme: light; }"))
    XCTAssertTrue(result.documentHTML.contains("background: #fff;"))
  }

  func testPresentationUsesHTMLAndFallsBackForMissingSanitizationOrRenderingFailure() {
    let body = MailboxMessageBody(text: "Readable fallback", html: "<p>Rich message</p>")
    let sanitized = SanitizedMessageHTML(bodyHTML: "<p>Rich message</p>", documentHTML: "document")

    XCTAssertEqual(
      MessageHTMLPresentation.resolve(body: body) { _ in sanitized },
      .html(sanitized)
    )
    XCTAssertEqual(
      MessageHTMLPresentation.resolve(body: body) { _ in nil },
      .plainText("Readable fallback")
    )
    XCTAssertEqual(
      MessageHTMLPresentation.resolve(body: body) { _ in throw TestError.sanitizationFailed },
      .plainText("Readable fallback")
    )
    XCTAssertEqual(
      MessageHTMLPresentation.resolve(
        body: body,
        renderingFailed: true,
        sanitizer: { _ in sanitized }
      ),
      .plainText("Readable fallback")
    )
    XCTAssertEqual(
      MessageHTMLPresentation.resolve(body: MailboxMessageBody(text: "Plain only")),
      .plainText("Plain only")
    )
  }

  @MainActor
  func testPresentationPreparationSanitizesOffTheMainThread() async {
    let body = MailboxMessageBody(text: "Readable fallback", html: "<p>Rich message</p>")

    let presentation = await MessageHTMLPresentation.prepare(body: body) { _ in
      SanitizedMessageHTML(
        bodyHTML: "<p>Rich message</p>",
        documentHTML: Thread.isMainThread ? "main" : "background"
      )
    }

    XCTAssertEqual(
      presentation,
      .html(
        SanitizedMessageHTML(
          bodyHTML: "<p>Rich message</p>",
          documentHTML: "background"
        )
      )
    )
  }

  func testLinkPolicyOpensAllowedSchemesOnlyForUserActivation() throws {
    let webURL = try XCTUnwrap(URL(string: "https://example.com/path"))
    let mailURL = try XCTUnwrap(URL(string: "mailto:person@example.com"))
    let phoneURL = try XCTUnwrap(URL(string: "tel:+420123456789"))
    let unsafeURL = try XCTUnwrap(URL(string: "javascript:alert('x')"))

    XCTAssertEqual(MessageHTMLLinkPolicy.externalURL(webURL, isUserActivated: true), webURL)
    XCTAssertEqual(MessageHTMLLinkPolicy.externalURL(mailURL, isUserActivated: true), mailURL)
    XCTAssertEqual(MessageHTMLLinkPolicy.externalURL(phoneURL, isUserActivated: true), phoneURL)
    XCTAssertNil(MessageHTMLLinkPolicy.externalURL(webURL, isUserActivated: false))
    XCTAssertNil(MessageHTMLLinkPolicy.externalURL(unsafeURL, isUserActivated: true))
  }

  func testWebViewConfigurationDisablesPageJavaScriptAndPersistentStorage() {
    let configuration = MessageHTMLWebViewConfiguration.make()
    let webView = WKWebView(frame: .zero, configuration: configuration)
    MessageHTMLWebViewConfiguration.applyPrivacySettings(to: webView)

    XCTAssertFalse(configuration.defaultWebpagePreferences.allowsContentJavaScript)
    XCTAssertFalse(configuration.websiteDataStore.isPersistent)
    XCTAssertFalse(webView.allowsLinkPreview)
  }

  func testLayoutUsesContentSizeAndViewportWithAVisibleMinimum() {
    let viewportSize = CGSize(width: 500, height: 800)

    XCTAssertEqual(MessageHTMLLayout.height(for: .zero), 1)
    XCTAssertFalse(
      MessageHTMLLayout.isInternallyScrollable(for: .zero, within: viewportSize)
    )
    XCTAssertEqual(MessageHTMLLayout.height(for: CGSize(width: 500, height: 128.5)), 128.5)
    XCTAssertFalse(
      MessageHTMLLayout.isInternallyScrollable(
        for: CGSize(width: 500, height: MessageHTMLLayout.maximumHeight),
        within: viewportSize
      )
    )
    XCTAssertTrue(
      MessageHTMLLayout.isInternallyScrollable(
        for: CGSize(width: 501, height: 128.5),
        within: viewportSize
      )
    )
    XCTAssertEqual(
      MessageHTMLLayout.height(for: CGSize(width: 500, height: 100_000_000)),
      MessageHTMLLayout.maximumHeight
    )
    XCTAssertTrue(
      MessageHTMLLayout.isInternallyScrollable(
        for: CGSize(width: 500, height: 100_000_000),
        within: viewportSize
      )
    )
  }

  func testNavigationFailureIgnoresIntentionalCancellation() {
    let urlCancellation = NSError(domain: NSURLErrorDomain, code: URLError.cancelled.rawValue)
    let policyCancellation = NSError(domain: "WebKitErrorDomain", code: 102)
    let failure = NSError(domain: NSURLErrorDomain, code: URLError.cannotConnectToHost.rawValue)

    XCTAssertFalse(MessageHTMLNavigationFailure.shouldTriggerFallback(for: urlCancellation))
    XCTAssertFalse(MessageHTMLNavigationFailure.shouldTriggerFallback(for: policyCancellation))
    XCTAssertTrue(MessageHTMLNavigationFailure.shouldTriggerFallback(for: failure))
  }
}

private enum TestError: Error {
  case sanitizationFailed
}
