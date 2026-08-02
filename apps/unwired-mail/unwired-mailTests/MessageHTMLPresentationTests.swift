import WebKit
import XCTest

@testable import unwired_mail

// swiftlint:disable file_length

final class MessageHTMLPresentationTests: XCTestCase {
  func testSanitizerPreservesCommonEmailLayoutAndSafeStyles() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <table width="100%" cellpadding="8" cellspacing="0" style="border-collapse: collapse">
          <tr>
            <td align="center" style="font-weight: bold; background-image: url(https://tracker.test/pixel)">
              <strong>Receipt</strong>
            </td>
          </tr>
        </table>
        """
      )
    )

    XCTAssertTrue(result.documentHTML.contains("<table"))
    XCTAssertTrue(result.documentHTML.contains("width=\"100%\""))
    XCTAssertTrue(result.documentHTML.contains("cellpadding=\"8\""))
    XCTAssertTrue(result.documentHTML.contains("border-collapse:collapse"))
    XCTAssertTrue(result.documentHTML.contains("font-weight:bold"))
    XCTAssertFalse(result.documentHTML.contains("background-image"))
    XCTAssertTrue(result.documentHTML.contains("<strong>Receipt</strong>"))
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
    let sanitized = result.documentHTML.lowercased()

    for forbidden in [
      "http-equiv=\"refresh\"", "<script", "<form", "<input", "<iframe", "<object", "onclick",
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

  func testSanitizerRecordsRemoteImagesWithoutExposingTheirURLsToWebKit() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <img src="https://images.example.com/hero.png" alt="Hero">
        <img src="http://legacy.example.com/chart.jpg" alt="Chart">
        <img src="cid:logo@example.com" alt="Logo">
        """
      )
    )

    XCTAssertEqual(
      result.remoteImageReferences.map(\.url.absoluteString),
      ["https://images.example.com/hero.png"]
    )
    XCTAssertEqual(
      result.remoteImageReferences.map(\.identifier),
      ["remote-image-0"]
    )
    XCTAssertTrue(
      result.documentHTML.contains(
        "data-unwired-remote-image=\"remote-image-0\""
      )
    )
    XCTAssertFalse(result.documentHTML.contains("remote-image-1"))
    XCTAssertFalse(result.documentHTML.contains("images.example.com"))
    XCTAssertFalse(result.documentHTML.contains("legacy.example.com"))
    XCTAssertTrue(result.documentHTML.contains("src=\"cid:logo@example.com\""))
  }

  func testSanitizerIgnoresSpoofedRemoteImageMarkersAndCredentialedURLs() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <img data-unwired-remote-image="remote-image-9" alt="Spoofed">
        <img src="https://user:secret@example.com/private.png" alt="Credentialed">
        """
      )
    )

    XCTAssertTrue(result.remoteImageReferences.isEmpty)
    XCTAssertFalse(result.documentHTML.contains("data-unwired-remote-image"))
    XCTAssertFalse(result.documentHTML.contains("secret"))
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

    XCTAssertTrue(result.documentHTML.contains("href=\"https://example.com\""))
    XCTAssertTrue(result.documentHTML.contains("href=\"mailto:person@example.com\""))
    XCTAssertTrue(result.documentHTML.contains("href=\"tel:+420123456789\""))
    XCTAssertFalse(result.documentHTML.contains("ftp://"))
    XCTAssertFalse(result.documentHTML.contains("href=\"/relative\""))
  }

  func testSanitizerHandlesMalformedMarkupAndRejectsEmptyActiveContent() throws {
    let malformed = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize("<table><tr><td><b>Readable")
    )

    XCTAssertTrue(malformed.documentHTML.contains("<b>Readable</b>"))
    XCTAssertNil(try MessageHTMLSanitizer.sanitize("<script>alert('only active content')</script>"))
    XCTAssertNil(try MessageHTMLSanitizer.sanitize(" \n\t "))
  }

  func testSanitizerRetainsImageOnlyCIDContent() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        #"<img src="cid:barcode@example.com" alt="Barcode">"#
      )
    )

    XCTAssertTrue(result.documentHTML.contains("src=\"cid:barcode@example.com\""))
  }

  func testReferencedInlineImagesIgnoreWhitespacePaddedZeroDimensions() {
    let contentIDs = MessageHTMLSanitizer.referencedInlineImageContentIDs(
      in: """
        <img src="cid:zero-width@example.com" width=" 0 ">
        <img src="cid:zero-height@example.com" height="\n0px\t">
        <img src="cid:zero-max-width@example.com" style="max-width: .0px !important">
        <img src="cid:visible@example.com">
        """
    )

    XCTAssertEqual(contentIDs, ["visible@example.com"])
  }

  func testSanitizerRetainsCIDImageInsideZeroLineHeightContainer() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Receipt</p>
        <div style="line-height: 0"><img src="cid:logo@example.com" alt="Logo"></div>
        """
      )
    )

    XCTAssertTrue(result.documentHTML.contains("src=\"cid:logo@example.com\""))
  }

  func testSanitizerRetainsCIDImageInsideZeroFontSizeContainer() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Receipt</p>
        <div style="font-size: 0"><img src="cid:logo@example.com" alt="Logo"></div>
        """
      )
    )

    XCTAssertTrue(result.documentHTML.contains("src=\"cid:logo@example.com\""))
  }

  func testSanitizerRetainsRemoteImageWithHiddenPreheaderText() throws {
    for hiddenAttribute in [
      "hidden",
      "style=\"display: none !important\"",
      "style=\"visibility: hidden\"",
    ] {
      let result = try XCTUnwrap(
        MessageHTMLSanitizer.sanitize(
          """
          <div \(hiddenAttribute)>Hidden preview</div>
          <img src="https://tracker.test/hero.png">
          """
        )
      )

      XCTAssertEqual(result.remoteImageReferences.count, 1)
      XCTAssertFalse(result.documentHTML.contains("Hidden preview"))
    }
  }

  func testSanitizerRetainsRemoteImageWithCSSHiddenPreheaderText() throws {
    for style in [
      "opacity: 0%", "opacity: -0.1", "font-size: 0", "height: 0px", "width: 0%",
      "line-height: 0.0em !important", "text-indent: -9999px", "margin: -9999px",
      "margin-left: -9999px", "margin-right: -9999px", "margin-top: -9999px",
    ] {
      let result = try XCTUnwrap(
        MessageHTMLSanitizer.sanitize(
          """
          <div style="\(style)">Hidden preview</div>
          <img src="https://tracker.test/hero.png">
          """
        )
      )

      XCTAssertEqual(result.remoteImageReferences.count, 1)
    }
  }

  func testSanitizerBlocksRemoteImagesWithZeroMaximumDimensions() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <img style="max-width: 0" src="https://tracker.example/width-pixel.gif">
        <img style="max-height: 0" src="https://tracker.example/height-pixel.gif">
        <img src="https://images.example.com/hero.png">
        """
      )
    )

    XCTAssertEqual(
      result.remoteImageReferences.map(\.url.absoluteString),
      ["https://images.example.com/hero.png"]
    )
    XCTAssertFalse(result.documentHTML.contains("tracker.example"))
  }

  func testSanitizerPreservesContentWithSmallNegativeLayoutOffsets() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <div style="margin-top: -1px">
          Visible details
        </div>
        """
      )
    )

    XCTAssertTrue(result.documentHTML.contains("Visible details"))
  }

  func testSanitizedDocumentUsesRestrictiveContentSecurityPolicy() throws {
    let result = try XCTUnwrap(MessageHTMLSanitizer.sanitize("<p>Hello</p>"))

    XCTAssertTrue(result.documentHTML.contains("default-src 'none'"))
    XCTAssertTrue(result.documentHTML.contains("img-src data:"))
    XCTAssertTrue(result.documentHTML.contains("connect-src 'none'"))
    XCTAssertTrue(result.documentHTML.contains("frame-src 'none'"))
    XCTAssertTrue(result.documentHTML.contains("object-src 'none'"))
    XCTAssertTrue(result.documentHTML.contains("base-uri 'none'"))
    XCTAssertTrue(result.documentHTML.contains("form-action 'none'"))
    XCTAssertTrue(result.documentHTML.contains("<p>Hello</p>"))
  }
}

extension MessageHTMLPresentationTests {
  func testSanitizerRetainsRemoteImageOnlyMessagesForConsent() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        #"<img src="https://images.example.com/receipt.png" alt="Receipt">"#
      )
    )

    XCTAssertEqual(
      result.remoteImageReferences.map(\.url.absoluteString),
      ["https://images.example.com/receipt.png"]
    )
    XCTAssertTrue(result.documentHTML.contains("data-unwired-remote-image"))
  }

  func testSanitizerIgnoresNonRenderingTextInRemoteImageOnlyMessages() throws {
    for nonRenderingElement in [
      "<style>img { display: block; }</style>",
      "<script>document.body.dataset.loaded = 'true';</script>",
    ] {
      let result = try XCTUnwrap(
        MessageHTMLSanitizer.sanitize(
          nonRenderingElement + #"<img src="https://images.example.com/receipt.png">"#
        )
      )

      XCTAssertEqual(
        result.remoteImageReferences.map(\.url.absoluteString),
        ["https://images.example.com/receipt.png"]
      )
    }
  }

  func testSanitizerExcludesInvisibleRemoteImagesAndDeduplicatesURLs() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <img src="https://tracker.example/pixel.gif" width="0" alt="Tracker">
        <img src="https://images.example.com/hero.png" alt="Hero">
        <img src="https://images.example.com/hero.png" alt="Repeated hero">
        """
      )
    )

    XCTAssertEqual(
      result.remoteImageReferences.map(\.url.absoluteString),
      ["https://images.example.com/hero.png"]
    )
    XCTAssertEqual(
      result.documentHTML.components(
        separatedBy: #"data-unwired-remote-image="remote-image-0""#
      ).count - 1,
      2
    )
    XCTAssertFalse(result.documentHTML.contains("tracker.example"))
    XCTAssertFalse(result.documentHTML.contains(#"alt="Tracker" src="#))
  }

  func testSanitizerDeduplicatesRequestEquivalentRemoteImageURLs() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <img src="HTTPS://images.example.com/hero.png" alt="Uppercase scheme hero">
        <img src="https://IMAGES.EXAMPLE.COM/hero.png#one" alt="Hero">
        <img src="https://images.example.com/hero.png#two" alt="Repeated hero">
        <img src="https://images.example.com:443/hero.png" alt="Default port hero">
        """
      )
    )

    XCTAssertEqual(
      result.remoteImageReferences.map(\.url.absoluteString),
      ["https://images.example.com/hero.png"]
    )
    XCTAssertEqual(
      result.documentHTML.components(
        separatedBy: #"data-unwired-remote-image="remote-image-0""#
      ).count - 1,
      4
    )
  }

  func testSanitizerDeduplicatesEmptyAndSlashRemoteImagePaths() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <img src="https://images.example.com" alt="Empty path">
        <img src="https://images.example.com/" alt="Slash path">
        """
      )
    )

    XCTAssertEqual(
      result.remoteImageReferences.map(\.url.absoluteString),
      ["https://images.example.com/"]
    )
    XCTAssertEqual(
      result.documentHTML.components(
        separatedBy: #"data-unwired-remote-image="remote-image-0""#
      ).count - 1,
      2
    )
  }

  func testSanitizerDeduplicatesPercentEscapeHexCasing() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <img src="https://images.example.com/%2fhero.png?token=%ab" alt="Lowercase escapes">
        <img src="https://images.example.com/%2Fhero.png?token=%AB" alt="Uppercase escapes">
        """
      )
    )

    XCTAssertEqual(
      result.remoteImageReferences.map(\.url.absoluteString),
      ["https://images.example.com/%2Fhero.png?token=%AB"]
    )
    XCTAssertEqual(
      result.documentHTML.components(
        separatedBy: #"data-unwired-remote-image="remote-image-0""#
      ).count - 1,
      2
    )
  }

  func testSanitizerDeduplicatesPercentEncodedUnreservedCharacters() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <img src="https://images.example.com/%70ixel.png" alt="Encoded path">
        <img src="https://images.example.com/pixel.png" alt="Literal path">
        """
      )
    )

    XCTAssertEqual(
      result.remoteImageReferences.map(\.url.absoluteString),
      ["https://images.example.com/pixel.png"]
    )
    XCTAssertEqual(
      result.documentHTML.components(
        separatedBy: #"data-unwired-remote-image="remote-image-0""#
      ).count - 1,
      2
    )
  }

  func testSanitizerDeduplicatesNormalizedURLDotSegments() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <img src="https://tracker.example/a/../pixel" alt="Literal dot segments">
        <img src="https://tracker.example/a/%2e%2e/pixel" alt="Encoded dot segments">
        <img src="https://tracker.example/pixel" alt="Normalized path">
        """
      )
    )

    XCTAssertEqual(
      result.remoteImageReferences.map(\.url.absoluteString),
      ["https://tracker.example/pixel"]
    )
    XCTAssertEqual(
      result.documentHTML.components(
        separatedBy: #"data-unwired-remote-image="remote-image-0""#
      ).count - 1,
      3
    )
  }

  func testPresentationResolvesNormalizedCIDImagesIntoLocalData() throws {
    let imageData = Data([0x89, 0x50, 0x4E, 0x47])
    let body = MailboxMessageBody(
      text: "Receipt",
      html: """
        <p>Receipt</p>
        <img src="CID:%49mage-001@Example.COM" alt="Barcode">
        """,
      inlineImages: [
        MailboxMessageInlineImage(
          contentID: " <image-001@example.com> ",
          data: imageData,
          decodedPixelCount: 1,
          mimeType: "image/png"
        )
      ]
    )

    guard case .html(let presentation) = MessageHTMLPresentation.resolve(body: body) else {
      return XCTFail("Expected sanitized HTML")
    }

    XCTAssertTrue(
      presentation.documentHTML.contains(
        "src=\"data:image/png;base64,\(imageData.base64EncodedString())\""
      )
    )
    XCTAssertFalse(presentation.documentHTML.lowercased().contains("cid:"))
  }

  func testPresentationBoundsRepeatedCIDImageSubstitutions() throws {
    let imageData = Data(repeating: 0x41, count: 5 * 1_024 * 1_024)
    let repeatedImages = String(
      repeating: #"<img src="cid:repeated@example.com" alt="Repeated">"#,
      count: 5
    )
    let body = MailboxMessageBody(
      text: "Repeated image",
      html: "<p>Repeated image</p>\(repeatedImages)",
      inlineImages: [
        MailboxMessageInlineImage(
          contentID: "repeated@example.com",
          data: imageData,
          decodedPixelCount: 1,
          mimeType: "image/png"
        )
      ]
    )

    guard case .html(let presentation) = MessageHTMLPresentation.resolve(body: body) else {
      return XCTFail("Expected sanitized HTML")
    }

    let dataSource = "src=\"data:image/png;base64,"
    XCTAssertEqual(presentation.documentHTML.components(separatedBy: dataSource).count - 1, 4)
    XCTAssertEqual(
      presentation.documentHTML.components(separatedBy: "alt=\"Repeated\"").count - 1,
      5
    )
    XCTAssertFalse(presentation.documentHTML.lowercased().contains("cid:"))
  }

  func testPresentationLeavesMissingCIDImagesAsNonLoadingPlaceholders() throws {
    let body = MailboxMessageBody(
      text: "Receipt",
      html: """
        <p>Receipt</p>
        <img src="cid:missing@example.com" alt="Missing image">
        <img src="https://tracker.example/pixel.gif" alt="Remote image">
        """
    )

    guard case .html(let presentation) = MessageHTMLPresentation.resolve(body: body) else {
      return XCTFail("Expected sanitized HTML")
    }

    XCTAssertTrue(presentation.documentHTML.contains("alt=\"Missing image\""))
    XCTAssertTrue(presentation.documentHTML.contains("alt=\"Remote image\""))
    XCTAssertFalse(presentation.documentHTML.lowercased().contains("cid:"))
    XCTAssertFalse(presentation.documentHTML.contains("tracker.example"))
    XCTAssertFalse(presentation.documentHTML.contains("<img src="))
  }

  func testSanitizerBlocksDeclaredOneByOneRemoteTrackingPixels() throws {
    let body = MailboxMessageBody(
      text: "Newsletter",
      html: """
        <p>Newsletter</p>
        <img src="https://tracker.example/pixel.gif" width="1" height="1px">
        <img src="https://images.example.com/logo.png" width="120" height="40">
        """
    )

    guard case .html(let presentation) = MessageHTMLPresentation.resolve(body: body) else {
      return XCTFail("Expected sanitized HTML")
    }

    XCTAssertEqual(
      presentation.remoteImageReferences.map(\.url.absoluteString),
      ["https://images.example.com/logo.png"]
    )
    XCTAssertFalse(presentation.documentHTML.contains("tracker.example"))
  }

  func testSanitizerBlocksCSSDeclaredOneByOneRemoteTrackingPixels() throws {
    let body = MailboxMessageBody(
      text: "Newsletter",
      html: """
        <p>Newsletter</p>
        <img src="https://tracker.example/pixel.gif"
             style="height: 1.0px !important; width: 01PX">
        <img src="https://tracker.example/max-width.gif"
             height="1" style="max-width: 1px">
        <img src="https://tracker.example/max-height.gif"
             width="1" style="max-height: 1px">
        <img src="https://tracker.example/signed-one.gif"
             style="width: +1px; height: +1px">
        <img src="https://tracker.example/signed-zero.gif"
             style="width: +0px; height: 1px">
        <img src="https://tracker.example/calculated-one.gif"
             style="width: calc(1px); height: calc(0px + 1px)">
        <img src="https://tracker.example/calculated-subtraction.gif"
             style="width: calc(2px - 1px); height: calc(3px - 2px)">
        <img src="https://tracker.example/point-one.gif"
             style="width: .75pt; height: .75pt">
        <img src="https://tracker.example/font-relative-one.gif"
             style="font-size: 1px; width: 1em; height: 1em">
        <img src="https://images.example.com/minimum-width.png"
             style="width: 1px; height: 1px; min-width: 600px">
        <img src="https://images.example.com/calculated-size.png"
             style="width: calc(3px - 1px); height: calc(4px - 2px)">
        <img src="https://images.example.com/logo.png"
             style="height: 40px; width: 120px">
        """
    )

    guard case .html(let presentation) = MessageHTMLPresentation.resolve(body: body) else {
      return XCTFail("Expected sanitized HTML")
    }

    XCTAssertEqual(
      presentation.remoteImageReferences.map(\.url.absoluteString),
      [
        "https://images.example.com/minimum-width.png",
        "https://images.example.com/calculated-size.png",
        "https://images.example.com/logo.png",
      ]
    )
    XCTAssertFalse(presentation.documentHTML.contains("tracker.example"))
    XCTAssertFalse(presentation.documentHTML.contains("max-width.gif"))
    XCTAssertFalse(presentation.documentHTML.contains("max-height.gif"))
    XCTAssertFalse(presentation.documentHTML.contains("signed-one.gif"))
    XCTAssertFalse(presentation.documentHTML.contains("signed-zero.gif"))
    XCTAssertFalse(presentation.documentHTML.contains("calculated-one.gif"))
    XCTAssertFalse(presentation.documentHTML.contains("calculated-subtraction.gif"))
    XCTAssertFalse(presentation.documentHTML.contains("point-one.gif"))
    XCTAssertFalse(presentation.documentHTML.contains("font-relative-one.gif"))
  }

  func testSanitizerBlocksRootFontRelativeTrackingPixel() throws {
    let body = MailboxMessageBody(
      text: "Newsletter",
      html: """
        <p>Newsletter</p>
        <img src="https://tracker.example/root-font-relative-one.gif"
             style="width: .0625rem; height: .0625rem">
        """
    )

    guard case .html(let presentation) = MessageHTMLPresentation.resolve(body: body) else {
      return XCTFail("Expected sanitized HTML")
    }

    XCTAssertTrue(presentation.remoteImageReferences.isEmpty)
    XCTAssertFalse(presentation.documentHTML.contains("root-font-relative-one.gif"))
  }

  func testSanitizerResolvesPercentageTrackingPixelsAgainstContainingBlock() throws {
    let body = MailboxMessageBody(
      text: "Newsletter",
      html: """
        <div style="width: 1px; height: 1px">
          <img src="https://tracker.example/percentage.gif"
               style="width: 100%; height: 100%">
        </div>
        <div style="width: 1px; height: 1px">
          <div style="width: 100%; height: 100%">
            <img src="https://tracker.example/nested-percentage.gif"
                 style="width: 100%; height: 100%">
          </div>
        </div>
        <div style="width: 1px; height: 1px">
          <span>
            <img src="https://tracker.example/inline-ancestor-percentage.gif"
                 style="width: 100%; height: 100%">
          </span>
        </div>
        <div style="width: 600px; max-width: 1px; height: 1px">
          <img src="https://tracker.example/constrained-percentage.gif"
               style="width: 100%; height: 100%">
        </div>
        <div style="width: 600px; height: 400px">
          <img src="https://images.example.com/hero.png"
               style="width: 100%; height: 100%">
        </div>
        <div style="width: 600px; height: 400px">
          <img src="https://images.example.com/percentage-minimum.png"
               style="width: 0; min-width: 100%; height: 40px">
        </div>
        """
    )

    guard case .html(let presentation) = MessageHTMLPresentation.resolve(body: body) else {
      return XCTFail("Expected sanitized HTML")
    }

    XCTAssertEqual(
      presentation.remoteImageReferences.map(\.url.absoluteString),
      [
        "https://images.example.com/hero.png",
        "https://images.example.com/percentage-minimum.png",
      ]
    )
    XCTAssertFalse(presentation.documentHTML.contains("percentage.gif"))
    XCTAssertFalse(presentation.documentHTML.contains("nested-percentage.gif"))
    XCTAssertFalse(presentation.documentHTML.contains("inline-ancestor-percentage.gif"))
    XCTAssertFalse(presentation.documentHTML.contains("constrained-percentage.gif"))
  }

  func testSanitizerResolvesPercentageWidthThroughAutoSizedBlock() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="width: 1px">
          <div>
            <img src="https://tracker.example/auto-block-percentage.gif"
                 style="width: 100%; height: 1px">
          </div>
        </div>
        """
      )
    )

    XCTAssertTrue(result.remoteImageReferences.isEmpty)
    XCTAssertFalse(result.documentHTML.contains("auto-block-percentage.gif"))
  }

  func testSanitizerIgnoresStrippedPositioningWhenResolvingPercentageWidth() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="width: 1px">
          <div style="position: absolute">
            <img src="https://tracker.example/stripped-position.gif"
                 style="width: 100%; height: 1px">
          </div>
        </div>
        """
      )
    )

    XCTAssertTrue(result.remoteImageReferences.isEmpty)
    XCTAssertFalse(result.documentHTML.contains("stripped-position.gif"))
  }

  func testSanitizerResolvesPercentageWidthThroughExplicitBlockSpan() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <span style="display: block; width: 1px; height: 1px">
          <img src="https://tracker.example/block-span-percentage.gif"
               style="width: 100%; height: 100%">
        </span>
        """
      )
    )

    XCTAssertTrue(result.remoteImageReferences.isEmpty)
    XCTAssertFalse(result.documentHTML.contains("block-span-percentage.gif"))
  }

  func testSanitizerAppliesMaximumToAutoBlockWidth() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="width: 600px">
          <div style="max-width: 1px">
            <img src="https://tracker.example/constrained-auto-block.gif"
                 style="width: 100%; height: 1px">
          </div>
        </div>
        """
      )
    )

    XCTAssertTrue(result.remoteImageReferences.isEmpty)
    XCTAssertFalse(result.documentHTML.contains("constrained-auto-block.gif"))
  }

  func testSanitizerParsesSpacedImportantImageDimensions() throws {
    let body = MailboxMessageBody(
      text: "Newsletter",
      html: """
        <img src="https://images.example.com/spaced-important.png"
             style="width: 1px !important; width: 600px ! important;
                    height: 1px !important; height: 400px ! important">
        """
    )

    guard case .html(let presentation) = MessageHTMLPresentation.resolve(body: body) else {
      return XCTFail("Expected sanitized HTML")
    }

    XCTAssertEqual(
      presentation.remoteImageReferences.map(\.url.absoluteString),
      ["https://images.example.com/spaced-important.png"]
    )
  }

  func testSanitizerResolvesRelativeImageDimensionsUsingInitialAndExplicitFontSizes() throws {
    let body = MailboxMessageBody(
      text: "Newsletter",
      html: """
        <img src="https://images.example.com/relative-minimum.png"
             style="font-size: 16px; width: 1px; height: 1px; min-width: 2em; min-height: 2em">
        <img src="https://tracker.example/initial-font-size.gif"
             style="font-size: initial; width: .0625em; height: .0625em">
        """
    )

    guard case .html(let presentation) = MessageHTMLPresentation.resolve(body: body) else {
      return XCTFail("Expected sanitized HTML")
    }

    XCTAssertEqual(
      presentation.remoteImageReferences.map(\.url.absoluteString),
      ["https://images.example.com/relative-minimum.png"]
    )
    XCTAssertFalse(presentation.documentHTML.contains("initial-font-size.gif"))
  }

  func testSanitizerBlocksFontRelativeTrackingPixelWithInheritedFontSize() throws {
    let body = MailboxMessageBody(
      text: "Newsletter",
      html: """
        <div style="font-size: 1px">
          <img src="https://tracker.example/inherited-font-relative-one.gif"
               style="width: 1em; height: 1em">
        </div>
        <div style="font-size: 2em">
          <div style="font-size: 50%">
            <img src="https://tracker.example/nested-font-relative-one.gif"
                 style="width: .0625em; height: .0625em">
          </div>
        </div>
        <img src="https://images.example.com/logo.png" style="height: 40px; width: 120px">
        """
    )

    guard case .html(let presentation) = MessageHTMLPresentation.resolve(body: body) else {
      return XCTFail("Expected sanitized HTML")
    }

    XCTAssertEqual(
      presentation.remoteImageReferences.map(\.url.absoluteString),
      ["https://images.example.com/logo.png"]
    )
    XCTAssertFalse(presentation.documentHTML.contains("inherited-font-relative-one.gif"))
    XCTAssertFalse(presentation.documentHTML.contains("nested-font-relative-one.gif"))
  }

  func testSanitizerRequiresMinimumDimensionsToExceedOnePixel() throws {
    let body = MailboxMessageBody(
      text: "Newsletter",
      html: """
        <img src="https://tracker.example/subpixel-minimum.gif"
             style="width: 1px; height: 1px; min-width: .5px">
        <img src="https://tracker.example/calculated-subpixel-minimum.gif"
             style="width: 1px; height: 1px; min-height: calc(.5px)">
        <img src="https://tracker.example/subpixel-point-minimum.gif"
             style="width: 1px; height: 1px; min-width: .5pt">
        <img src="https://tracker.example/constrained-one.gif"
             style="width: 2px; height: 2px; max-width: 0; max-height: 0;
                    min-width: 1px; min-height: 1px">
        <img src="https://images.example.com/point-minimum.png"
             style="width: 1px; height: 1px; min-width: 1pt">
        <img src="https://images.example.com/minimum-height.png"
             style="width: 1px; height: 1px; min-height: 600px">
        """
    )

    guard case .html(let presentation) = MessageHTMLPresentation.resolve(body: body) else {
      return XCTFail("Expected sanitized HTML")
    }

    XCTAssertEqual(
      presentation.remoteImageReferences.map(\.url.absoluteString),
      [
        "https://images.example.com/point-minimum.png",
        "https://images.example.com/minimum-height.png",
      ]
    )
    XCTAssertFalse(presentation.documentHTML.contains("tracker.example"))
    XCTAssertTrue(presentation.documentHTML.contains("min-height:600px"))
  }

  func testSanitizerDoesNotRetainRemoteImagesInsideOffCanvasWrappers() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="margin-left: -9999px">
          <img src="https://tracker.example/off-canvas.gif">
        </div>
        <img src="https://images.example.com/logo.png">
        """
      )
    )

    XCTAssertEqual(
      result.remoteImageReferences.map(\.url.absoluteString),
      ["https://images.example.com/logo.png"]
    )
    XCTAssertFalse(
      result.documentHTML.contains(RemoteMessageContentMarkup.attribute + "=\"remote-image-0\""))
  }

  func testSanitizerDoesNotRetainRemoteImagesInsideCalculatedOffCanvasWrappers() throws {
    for style in [
      "margin: calc(-9999px)", "text-indent: calc(-9999px)", "margin-left: -99in",
      "margin-left: min(-9999px, -100px)", "margin-left: max(-9999px, -100px)",
      "margin-left: clamp(-9999px, -500px, -100px)",
    ] {
      let result = try XCTUnwrap(
        MessageHTMLSanitizer.sanitize(
          """
          <p>Newsletter</p>
          <div style="\(style)">
            <img src="https://tracker.example/off-canvas.gif">
          </div>
          <img src="https://images.example.com/logo.png">
          """
        )
      )

      XCTAssertEqual(
        result.remoteImageReferences.map(\.url.absoluteString),
        ["https://images.example.com/logo.png"],
        style
      )
      XCTAssertFalse(result.documentHTML.contains("off-canvas.gif"), style)
    }
  }

  func testSanitizerRetainsRemoteImagesOffsetByKnownPrecedingFlow() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <div style="height:200px">Spacer</div>
        <div style="margin-top:-100px">
          <img src="https://images.example.com/visible.png">
        </div>
        """
      )
    )

    XCTAssertEqual(
      result.remoteImageReferences.map(\.url.absoluteString),
      ["https://images.example.com/visible.png"]
    )
  }

  func testSanitizerRetainsRemoteImagesOffsetByIntrinsicPrecedingFlow() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <div>
          Line one<br>Line two<br>Line three<br>Line four<br>Line five<br>Line six
        </div>
        <div style="margin-top:-100px">
          <img src="https://images.example.com/visible.png">
        </div>
        """
      )
    )

    XCTAssertEqual(
      result.remoteImageReferences.map(\.url.absoluteString),
      ["https://images.example.com/visible.png"]
    )
  }

  func testSanitizerIgnoresNonBoxGeneratingPrecedingFlowHeights() throws {
    for display in ["inline", "contents"] {
      let result = try XCTUnwrap(
        MessageHTMLSanitizer.sanitize(
          """
          <span style="display:\(display);height:200px">Spacer</span>
          <div style="margin-top:-100px">
            <img src="https://tracker.example/off-canvas.gif">
          </div>
          """
        )
      )

      XCTAssertTrue(result.remoteImageReferences.isEmpty, display)
      XCTAssertFalse(result.documentHTML.contains("off-canvas.gif"), display)
    }
  }

  func testSanitizerRetainsRemoteImagesInsideNonOffsettingNegativeMargins() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="margin-right: -100px">
          <img src="https://images.example.com/right-margin.png">
        </div>
        <div style="margin-bottom: -100px">
          <img src="https://images.example.com/bottom-margin.png">
        </div>
        """
      )
    )

    XCTAssertEqual(
      result.remoteImageReferences.map(\.url.absoluteString),
      [
        "https://images.example.com/right-margin.png",
        "https://images.example.com/bottom-margin.png",
      ]
    )
  }

  func testSanitizerRetainsRemoteImageOffsetBackIntoViewport() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <div style="padding-left: 200px">
          <img style="margin-left: -100px" src="https://images.example.com/hero.png">
        </div>
        """
      )
    )

    XCTAssertEqual(
      result.remoteImageReferences.map(\.url.absoluteString),
      ["https://images.example.com/hero.png"]
    )
  }

  func testSanitizerRetainsIndentedRemoteImageOffsetByContainerPadding() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <div style="padding-left:200px;text-indent:-100px">
          <img src="https://images.example.com/hero.png">
        </div>
        """
      )
    )

    XCTAssertEqual(
      result.remoteImageReferences.map(\.url.absoluteString),
      ["https://images.example.com/hero.png"]
    )
  }

  func testSanitizerRetainsOverflowFromZeroSizedContainer() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <div style="width: 0">
          <img style="width: 600px; height: 100px" src="https://images.example.com/hero.png">
        </div>
        """
      )
    )

    XCTAssertEqual(
      result.remoteImageReferences.map(\.url.absoluteString),
      ["https://images.example.com/hero.png"]
    )
  }

  func testSanitizerRemovesRemoteImagesWithSignedZeroDimensions() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <img style="max-width: +0px" src="https://tracker.example/wrapped.gif">
        <img src="https://images.example.com/logo.png">
        """
      )
    )

    XCTAssertEqual(
      result.remoteImageReferences.map(\.url.absoluteString),
      ["https://images.example.com/logo.png"]
    )
    XCTAssertFalse(result.documentHTML.contains("wrapped.gif"))
  }

  func testSanitizerHonorsCSSDimensionsOverTrackingPixelAttributes() throws {
    let body = MailboxMessageBody(
      text: "Newsletter",
      html: """
        <p>Newsletter</p>
        <img src="https://images.example.com/hero.png" width="1" height="1"
             style="width: 600px; height: 300px">
        """
    )

    guard case .html(let presentation) = MessageHTMLPresentation.resolve(body: body) else {
      return XCTFail("Expected sanitized HTML")
    }

    XCTAssertEqual(
      presentation.remoteImageReferences.map(\.url.absoluteString),
      ["https://images.example.com/hero.png"]
    )
  }

  func testSanitizerRequiresValidCSSToOverrideTrackingPixelAttributes() throws {
    let body = MailboxMessageBody(
      text: "Newsletter",
      html: """
        <p>Newsletter</p>
        <img src="https://tracker.example/pixel.gif" width="1" height="1"
             style="width: bogus">
        """
    )

    guard case .html(let presentation) = MessageHTMLPresentation.resolve(body: body) else {
      return XCTFail("Expected sanitized HTML")
    }

    XCTAssertTrue(presentation.remoteImageReferences.isEmpty)
    XCTAssertFalse(presentation.documentHTML.contains("tracker.example"))
  }

  func testSanitizerHonorsCSSDimensionsOverZeroAttributes() throws {
    let body = MailboxMessageBody(
      text: "Newsletter",
      html: """
        <p>Newsletter</p>
        <img src="https://images.example.com/hero.png" width="0" height="0"
             style="width: 600px; height: 300px">
        """
    )

    guard case .html(let presentation) = MessageHTMLPresentation.resolve(body: body) else {
      return XCTFail("Expected sanitized HTML")
    }

    XCTAssertEqual(
      presentation.remoteImageReferences.map(\.url.absoluteString),
      ["https://images.example.com/hero.png"]
    )
  }

  func testRemoteContentLoaderAdmitsOnlyBoundedHTTPSRasterResponses() async throws {
    let presentation = try remoteContentTestPresentation()
    let png = try XCTUnwrap(
      Data(
        base64Encoded:
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
      )
    )
    let loader = RemoteMessageContentLoader(fetch: { request, maximumByteCount in
      XCTAssertEqual(request.url?.scheme, "https")
      XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
      XCTAssertEqual(request.httpShouldHandleCookies, false)
      XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
      XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
      XCTAssertNil(request.value(forHTTPHeaderField: "Referer"))
      XCTAssertEqual(maximumByteCount, MailboxMessageImagePolicy.maximumImageByteCount)
      let mimeType =
        request.url?.lastPathComponent == "hero.png"
        ? "image/png"
        : "text/html"
      return (
        request.url?.lastPathComponent == "hero.png" ? png : Data("<script></script>".utf8),
        try XCTUnwrap(
          HTTPURLResponse(
            url: try XCTUnwrap(request.url),
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": mimeType]
          )
        )
      )
    })

    let result = try await loader.load(presentation)

    XCTAssertEqual(result.loadedImageCount, 1)
    XCTAssertEqual(result.failedImageCount, 1)
    XCTAssertEqual(
      Set(result.html.remoteImageReferences.map(\.url.absoluteString)),
      ["https://images.example.com/not-an-image"]
    )
    XCTAssertTrue(result.html.documentHTML.contains("src=\"data:image/png;base64,"))
    XCTAssertFalse(result.html.documentHTML.contains("<script"))
    XCTAssertFalse(result.html.documentHTML.contains("images.example.com"))
    XCTAssertFalse(result.html.documentHTML.contains("legacy.example.com"))
  }

  func testRemoteContentLoaderChargesRejectedResponsesAgainstTransferBudget() async throws {
    let (result, requestedMaximumByteCounts) = try await remoteContentTransferBudgetResult(
      referenceCount: 4,
      fetch: { request, maximumByteCount in
        return (
          Data(repeating: 1, count: min(maximumByteCount, 4)),
          try XCTUnwrap(
            HTTPURLResponse(
              url: try XCTUnwrap(request.url),
              statusCode: 200,
              httpVersion: nil,
              headerFields: ["Content-Type": "text/plain"]
            )
          )
        )
      }
    )

    XCTAssertEqual(requestedMaximumByteCounts, [10, 6, 2])
    XCTAssertEqual(result.loadedByteCount, 0)
    XCTAssertEqual(result.loadedImageCount, 0)
    XCTAssertEqual(result.failedImageCount, 4)
    XCTAssertEqual(
      result.html.remoteImageReferences.first?.url.absoluteString,
      "https://images.example.com/image-3"
    )
  }

  func testRemoteContentLoaderRejectsTruncatedImageAfterReadingDimensions() async throws {
    let presentation = try remoteContentTestPresentation()
    let png = try XCTUnwrap(
      Data(
        base64Encoded:
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
      )
    )
    let loader = RemoteMessageContentLoader(fetch: { request, _ in
      (
        Data(png.prefix(33)),
        try XCTUnwrap(
          HTTPURLResponse(
            url: try XCTUnwrap(request.url),
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "image/png"]
          )
        )
      )
    })

    let result = try await loader.load(presentation)

    XCTAssertEqual(result.loadedImageCount, 0)
    XCTAssertEqual(result.failedImageCount, presentation.remoteImageReferences.count)
    XCTAssertEqual(result.html.remoteImageReferences, presentation.remoteImageReferences)
    XCTAssertFalse(result.html.documentHTML.contains("src=\"data:image/png;base64,"))
  }

  func testRemoteContentLoaderChargesOversizedFailuresAgainstTransferBudget() async throws {
    let (result, requestedMaximumByteCounts) = try await remoteContentTransferBudgetResult(
      referenceCount: 2,
      fetch: { _, maximumByteCount in
        throw RemoteMessageContentError.responseTooLarge(
          receivedByteCount: maximumByteCount
        )
      }
    )

    XCTAssertEqual(requestedMaximumByteCounts, [10])
    XCTAssertEqual(result.loadedByteCount, 0)
    XCTAssertEqual(result.loadedImageCount, 0)
    XCTAssertEqual(result.failedImageCount, 2)
  }

  func testRemoteContentLoaderChargesPartialTransferFailuresAgainstTransferBudget() async throws {
    let (result, requestedMaximumByteCounts) = try await remoteContentTransferBudgetResult(
      referenceCount: 4,
      fetch: { _, maximumByteCount in
        throw RemoteMessageContentError.transferFailed(
          receivedByteCount: min(maximumByteCount, 4)
        )
      }
    )

    XCTAssertEqual(requestedMaximumByteCounts, [10, 6, 2])
    XCTAssertEqual(result.loadedByteCount, 0)
    XCTAssertEqual(result.loadedImageCount, 0)
    XCTAssertEqual(result.failedImageCount, 4)
  }

  func testRemoteContentDataDelegateReportsBytesReceivedBeforeTransferFailure() async throws {
    PartialFailureURLProtocol.startSignal.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PartialFailureURLProtocol.self]
    let delegate = RemoteMessageContentDataDelegate(maximumByteCount: 10)
    let request = URLRequest(
      url: try XCTUnwrap(URL(string: "https://images.example.com/partial.png"))
    )
    let load = Task {
      try await delegate.load(request, configuration: configuration)
    }
    await PartialFailureURLProtocol.startSignal.waitUntilStarted()
    let session = URLSession(configuration: .ephemeral)
    let dataTask = session.dataTask(with: request)
    let response = try XCTUnwrap(
      HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "image/png"]
      )
    )
    delegate.urlSession(session, dataTask: dataTask, didReceive: response) { disposition in
      XCTAssertEqual(disposition, .allow)
    }
    delegate.urlSession(session, dataTask: dataTask, didReceive: PartialFailureURLProtocol.data)
    delegate.urlSession(
      session,
      task: dataTask,
      didCompleteWithError: URLError(.networkConnectionLost)
    )
    session.invalidateAndCancel()

    do {
      _ = try await load.value
      XCTFail("Expected the partial transfer to fail")
    } catch RemoteMessageContentError.transferFailed(let receivedByteCount) {
      XCTAssertEqual(receivedByteCount, PartialFailureURLProtocol.data.count)
    } catch {
      XCTFail("Expected a counted transfer failure, got \(error)")
    }
  }

  func testRemoteContentDataDelegateReportsOverflowingChunkBytes() async throws {
    PartialFailureURLProtocol.startSignal.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PartialFailureURLProtocol.self]
    let delegate = RemoteMessageContentDataDelegate(maximumByteCount: 5)
    let request = URLRequest(
      url: try XCTUnwrap(URL(string: "https://images.example.com/oversized.png"))
    )
    let load = Task {
      try await delegate.load(request, configuration: configuration)
    }
    await PartialFailureURLProtocol.startSignal.waitUntilStarted()
    let session = URLSession(configuration: .ephemeral)
    let dataTask = session.dataTask(with: request)
    let response = try XCTUnwrap(
      HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "image/png"]
      )
    )
    delegate.urlSession(session, dataTask: dataTask, didReceive: response) { disposition in
      XCTAssertEqual(disposition, .allow)
    }
    delegate.urlSession(session, dataTask: dataTask, didReceive: Data(repeating: 0, count: 4))
    delegate.urlSession(session, dataTask: dataTask, didReceive: Data(repeating: 0, count: 3))
    session.invalidateAndCancel()

    do {
      _ = try await load.value
      XCTFail("Expected the transfer to exceed the byte limit")
    } catch RemoteMessageContentError.responseTooLarge(let receivedByteCount) {
      XCTAssertEqual(receivedByteCount, 7)
    } catch {
      XCTFail("Expected a counted response-too-large failure, got \(error)")
    }
  }

  func testRemoteContentLoaderPropagatesCancellation() async throws {
    let body = MailboxMessageBody(
      text: "Newsletter",
      html: #"<p>Newsletter</p><img src="https://images.example.com/hero.png">"#
    )
    guard case .html(let presentation) = MessageHTMLPresentation.resolve(body: body) else {
      return XCTFail("Expected sanitized HTML")
    }
    let loader = RemoteMessageContentLoader(fetch: { _, _ in
      throw CancellationError()
    })

    do {
      _ = try await loader.load(presentation)
      XCTFail("Cancellation should stop remote content loading")
    } catch is CancellationError {
    } catch {
      XCTFail("Expected cancellation, got \(error)")
    }
  }

  func testRemoteContentLoaderAppliesAttemptCapAfterFilteringUnloadableURLs() async throws {
    let invalidReferences = try (0..<MailboxMessageImagePolicy.maximumImageAttemptCount).map {
      RemoteMessageImageReference(
        identifier: "remote-image-\($0)",
        url: try XCTUnwrap(URL(string: "http://legacy.example.com/image-\($0).png"))
      )
    }
    let validReference = RemoteMessageImageReference(
      identifier: "remote-image-valid",
      url: try XCTUnwrap(URL(string: "https://images.example.com/hero.png"))
    )
    let presentation = SanitizedMessageHTML(
      documentHTML:
        #"<html><body><img data-unwired-remote-image="remote-image-valid"></body></html>"#,
      remoteImageReferences: invalidReferences + [validReference]
    )
    let png = try XCTUnwrap(
      Data(
        base64Encoded:
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
      )
    )
    let loader = RemoteMessageContentLoader(fetch: { request, _ in
      XCTAssertEqual(request.url, validReference.url)
      return (
        png,
        try XCTUnwrap(
          HTTPURLResponse(
            url: validReference.url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "image/png"]
          )
        )
      )
    })

    let result = try await loader.load(presentation)

    XCTAssertEqual(result.loadedImageCount, 1)
    XCTAssertEqual(result.failedImageCount, invalidReferences.count)
    XCTAssertTrue(result.html.documentHTML.contains("src=\"data:image/png;base64,"))
  }

  func testRemoteContentLoaderAdvancesRetriesPastFailedAttemptBatch() async throws {
    let references = try (0...MailboxMessageImagePolicy.maximumImageAttemptCount).map {
      RemoteMessageImageReference(
        identifier: "remote-image-\($0)",
        url: try XCTUnwrap(URL(string: "https://images.example.com/image-\($0).png"))
      )
    }
    let markers = references.map {
      #"<img data-unwired-remote-image="\#($0.identifier)">"#
    }.joined()
    let presentation = SanitizedMessageHTML(
      documentHTML: "<html><body>\(markers)</body></html>",
      remoteImageReferences: references
    )
    let png = try XCTUnwrap(
      Data(
        base64Encoded:
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
      )
    )
    let validURL = try XCTUnwrap(references.last?.url)
    let loader = RemoteMessageContentLoader(fetch: { request, _ in
      guard request.url == validURL else { throw URLError(.badServerResponse) }
      return (
        png,
        try XCTUnwrap(
          HTTPURLResponse(
            url: validURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "image/png"]
          )
        )
      )
    })

    let firstResult = try await loader.load(presentation)
    let retryResult = try await loader.load(firstResult.html)

    XCTAssertEqual(firstResult.loadedImageCount, 0)
    XCTAssertEqual(firstResult.html.remoteImageReferences.first?.url, validURL)
    XCTAssertEqual(retryResult.loadedImageCount, 1)
  }

  func testRemoteContentLoaderStopsAtAggregateDeadline() async throws {
    var currentTime: TimeInterval = 0
    let references = try (0..<2).map {
      RemoteMessageImageReference(
        identifier: "remote-image-\($0)",
        url: try XCTUnwrap(URL(string: "https://images.example.com/image-\($0).png"))
      )
    }
    let markers = references.map {
      #"<img data-unwired-remote-image="\#($0.identifier)">"#
    }.joined()
    var requestedURLs: [URL] = []
    let loader = RemoteMessageContentLoader(
      maximumLoadDuration: 30,
      monotonicTime: { currentTime },
      fetch: { request, _ in
        requestedURLs.append(try XCTUnwrap(request.url))
        XCTAssertEqual(request.timeoutInterval, 30)
        currentTime += 31
        throw URLError(.timedOut)
      }
    )

    let result = try await loader.load(
      SanitizedMessageHTML(
        documentHTML: "<html><body>\(markers)</body></html>",
        remoteImageReferences: references
      )
    )

    XCTAssertEqual(requestedURLs, [references[0].url])
    XCTAssertEqual(result.failedImageCount, 2)
  }

  func testRemoteContentLoaderChargesRepeatedMarkerExpansionsAgainstByteBudget() async throws {
    let reference = RemoteMessageImageReference(
      identifier: "remote-image-0",
      url: try XCTUnwrap(URL(string: "https://images.example.com/hero.png"))
    )
    let repeatedMarkers = String(
      repeating: #"<img data-unwired-remote-image="remote-image-0">"#,
      count: 5
    )
    let presentation = SanitizedMessageHTML(
      documentHTML: "<html><body>\(repeatedMarkers)</body></html>",
      remoteImageReferences: [reference]
    )
    let png = try XCTUnwrap(
      Data(
        base64Encoded:
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
      )
    )
    let loader = RemoteMessageContentLoader(fetch: { _, maximumByteCount in
      XCTAssertEqual(
        maximumByteCount,
        MailboxMessageImagePolicy.maximumTotalByteCount / 5
      )
      return (
        png,
        try XCTUnwrap(
          HTTPURLResponse(
            url: reference.url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "image/png"]
          )
        )
      )
    })

    let result = try await loader.load(presentation)

    XCTAssertEqual(result.loadedImageCount, 1)
    XCTAssertEqual(
      result.html.documentHTML.components(separatedBy: "src=\"data:image/png;base64,").count - 1,
      5
    )
  }

  func testRemoteContentLoaderSkipsOverBudgetReferenceAndLoadsLaterImage() async throws {
    let references = try (0..<2).map {
      RemoteMessageImageReference(
        identifier: "remote-image-\($0)",
        url: try XCTUnwrap(URL(string: "https://images.example.com/image-\($0).png"))
      )
    }
    let presentation = SanitizedMessageHTML(
      documentHTML: """
        <img data-unwired-remote-image="remote-image-0">
        <img data-unwired-remote-image="remote-image-0">
        <img data-unwired-remote-image="remote-image-1">
        """,
      remoteImageReferences: references
    )
    let png = try XCTUnwrap(
      Data(
        base64Encoded:
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
      )
    )
    var requestedURLs: [URL] = []
    let loader = RemoteMessageContentLoader(
      maximumTotalPixelCount: 1,
      fetch: { request, _ in
        let url = try XCTUnwrap(request.url)
        requestedURLs.append(url)
        return (
          png,
          try XCTUnwrap(
            HTTPURLResponse(
              url: url,
              statusCode: 200,
              httpVersion: nil,
              headerFields: ["Content-Type": "image/png"]
            )
          )
        )
      }
    )

    let result = try await loader.load(presentation)

    XCTAssertEqual(requestedURLs, [references[1].url])
    XCTAssertEqual(result.loadedImageCount, 1)
    XCTAssertEqual(result.html.remoteImageReferences, [references[0]])
  }

  func testRemoteContentSessionUsesEphemeralCookieFreeStorage() {
    let configuration = RemoteMessageContentSession.makeConfiguration()

    XCTAssertFalse(configuration.httpShouldSetCookies)
    XCTAssertNil(configuration.httpCookieStorage)
    XCTAssertNil(configuration.urlCredentialStorage)
    XCTAssertNil(configuration.urlCache)
    XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    XCTAssertEqual(configuration.timeoutIntervalForResource, 30)
  }

  func testRemoteContentRedirectsRemainHTTPSAndDropRequestIdentity() throws {
    var secureRequest = URLRequest(
      url: try XCTUnwrap(URL(string: "https://cdn.example.com/image.png"))
    )
    secureRequest.httpShouldHandleCookies = true
    secureRequest.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
    secureRequest.setValue("session=secret", forHTTPHeaderField: "Cookie")
    secureRequest.setValue("https://mail.example.com/message", forHTTPHeaderField: "Referer")

    let redirectedRequest = try XCTUnwrap(
      RemoteMessageContentRedirectPolicy.redirectedRequest(secureRequest)
    )

    XCTAssertFalse(redirectedRequest.httpShouldHandleCookies)
    XCTAssertNil(redirectedRequest.value(forHTTPHeaderField: "Authorization"))
    XCTAssertNil(redirectedRequest.value(forHTTPHeaderField: "Cookie"))
    XCTAssertNil(redirectedRequest.value(forHTTPHeaderField: "Referer"))
    XCTAssertNil(
      RemoteMessageContentRedirectPolicy.redirectedRequest(
        URLRequest(url: try XCTUnwrap(URL(string: "http://cdn.example.com/image.png")))
      )
    )
  }

  func testRemoteContentRedirectsStopAfterThreeHops() throws {
    let delegate = RemoteMessageContentRedirectDelegate()
    let session = URLSession(configuration: .ephemeral)
    let task = session.dataTask(
      with: try XCTUnwrap(URL(string: "https://images.example.com/start.png"))
    )
    let response = try XCTUnwrap(
      HTTPURLResponse(
        url: try XCTUnwrap(URL(string: "https://images.example.com/start.png")),
        statusCode: 302,
        httpVersion: nil,
        headerFields: nil
      )
    )

    for hop in 1...4 {
      var redirectedRequest: URLRequest?
      delegate.urlSession(
        session,
        task: task,
        willPerformHTTPRedirection: response,
        newRequest: URLRequest(
          url: try XCTUnwrap(URL(string: "https://images.example.com/hop-\(hop).png"))
        )
      ) { request in
        redirectedRequest = request
      }
      if hop <= 3 {
        XCTAssertNotNil(redirectedRequest)
      } else {
        XCTAssertNil(redirectedRequest)
      }
    }

    session.invalidateAndCancel()
  }

  @MainActor
  func testRemoteContentPresentationRequiresConsentAndRetriesUnresolvedImages() async throws {
    let originalHTML = try remoteContentTestPresentation()
    let presentation = RemoteMessageContentPresentation()
    var receivedHTML: [SanitizedMessageHTML] = []
    let partiallyLoadedHTML = SanitizedMessageHTML(
      documentHTML: originalHTML.documentHTML.replacingOccurrences(
        of: #"data-unwired-remote-image="remote-image-0""#,
        with: #"src="data:image/png;base64,AA==""#
      ),
      remoteImageReferences: Array(originalHTML.remoteImageReferences.dropFirst())
    )
    let loader: (SanitizedMessageHTML) async throws -> RemoteMessageContentLoadResult = { html in
      receivedHTML.append(html)
      return RemoteMessageContentLoadResult(
        failedImageCount: partiallyLoadedHTML.remoteImageReferences.count,
        html: partiallyLoadedHTML,
        loadedImageCount: 1
      )
    }

    await presentation.load(originalHTML: originalHTML, using: loader)

    XCTAssertTrue(receivedHTML.isEmpty)
    XCTAssertEqual(presentation.state, .blocked)

    presentation.requestLoad()
    XCTAssertEqual(
      presentation.displayedHTML(originalHTML: originalHTML),
      originalHTML
    )
    await presentation.load(originalHTML: originalHTML, using: loader)
    presentation.requestLoad()
    XCTAssertEqual(
      presentation.displayedHTML(originalHTML: originalHTML),
      partiallyLoadedHTML
    )
    await presentation.load(originalHTML: originalHTML, using: loader)

    XCTAssertEqual(receivedHTML, [originalHTML, partiallyLoadedHTML])
    XCTAssertEqual(
      presentation.displayedHTML(originalHTML: originalHTML),
      partiallyLoadedHTML
    )
    XCTAssertEqual(
      presentation.state,
      .failed(partiallyLoadedHTML.remoteImageReferences.count)
    )

    presentation.reset()

    XCTAssertNil(presentation.loadRequest)
    XCTAssertEqual(presentation.state, .blocked)
    XCTAssertEqual(
      presentation.displayedHTML(originalHTML: originalHTML),
      originalHTML
    )
  }

  @MainActor
  func testResolvedCIDImageRendersInsideSecuredWebView() async throws {
    let imageData = try XCTUnwrap(
      Data(
        base64Encoded:
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
      )
    )
    let body = MailboxMessageBody(
      text: "Receipt",
      html: #"<p>Receipt</p><img src="cid:pixel@example.com">"#,
      inlineImages: [
        MailboxMessageInlineImage(
          contentID: "pixel@example.com",
          data: imageData,
          decodedPixelCount: 1,
          mimeType: "image/png"
        )
      ]
    )
    guard case .html(let presentation) = MessageHTMLPresentation.resolve(body: body) else {
      return XCTFail("Expected sanitized HTML")
    }
    let configuration = MessageHTMLWebViewConfiguration.make()
    let webView = WKWebView(frame: .zero, configuration: configuration)
    MessageHTMLWebViewConfiguration.applyPrivacySettings(to: webView)
    let navigationFinished = expectation(description: "Inline image document loaded")
    let navigationDelegate = MessageHTMLTestNavigationDelegate(expectation: navigationFinished)
    webView.navigationDelegate = navigationDelegate

    webView.loadHTMLString(presentation.documentHTML, baseURL: nil)
    await fulfillment(of: [navigationFinished], timeout: 5)

    XCTAssertNil(navigationDelegate.error)
    let didRender =
      try await webView.evaluateJavaScript(
        "document.images.length === 1 && document.images[0].complete "
          + "&& document.images[0].naturalWidth === 1"
      ) as? Bool
    XCTAssertEqual(didRender, true)
  }

  func testSanitizedDocumentNormalizesEmailColorsOntoANeutralLightCanvas() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <p style="color: #fff; background-color: #000;
          background-image: url(https://example.com/background.png)">Hello</p>
        """
      )
    )

    XCTAssertFalse(result.documentHTML.contains("style=\"color:"))
    XCTAssertFalse(result.documentHTML.contains("background-image"))
    XCTAssertTrue(result.documentHTML.contains(":root { color-scheme: light; }"))
    XCTAssertTrue(result.documentHTML.contains("background: #fff;"))
    XCTAssertTrue(result.documentHTML.contains("color: #111;"))
  }

  func testPresentationUsesHTMLAndFallsBackForMissingSanitizationOrRenderingFailure() {
    let body = MailboxMessageBody(text: "Readable fallback", html: "<p>Rich message</p>")
    let sanitized = SanitizedMessageHTML(documentHTML: "document")

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
  func testPresentationPreparationSanitizesOffTheMainThread() async throws {
    let body = MailboxMessageBody(text: "Readable fallback", html: "<p>Rich message</p>")

    let presentation = try await MessageHTMLPresentation.prepare(body: body) { _ in
      SanitizedMessageHTML(
        documentHTML: Thread.isMainThread ? "main" : "background"
      )
    }

    XCTAssertEqual(
      presentation,
      .html(
        SanitizedMessageHTML(
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

  @MainActor
  func testInitialWebViewSizeObservationDefersHeightChange() async {
    let heightChanged = expectation(description: "Height change delivered")
    var height: CGFloat?
    let coordinator = MessageHTMLWebView.Coordinator(
      onHeightChange: {
        height = $0
        heightChanged.fulfill()
      },
      onOpenURL: { _ in },
      onRenderingFailure: {}
    )
    let webView = WKWebView(
      frame: .zero,
      configuration: MessageHTMLWebViewConfiguration.make()
    )

    coordinator.observeContentSize(of: webView)

    XCTAssertNil(height, "Initial observation must not mutate SwiftUI state synchronously")
    await fulfillment(of: [heightChanged], timeout: 1)
    XCTAssertEqual(height, 1)
    coordinator.stopObservingContentSize()
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
    XCTAssertFalse(
      MessageHTMLLayout.isInternallyScrollable(
        for: CGSize(width: 501, height: 128.5),
        within: CGSize(width: 502, height: 800)
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

extension MessageHTMLPresentationTests {
  func testPresentationPreparationCancelsDetachedSanitization() async {
    let body = MailboxMessageBody(text: "Readable fallback", html: "<p>Rich message</p>")
    let sanitizationStarted = DispatchSemaphore(value: 0)
    let allowSanitizationToFinish = DispatchSemaphore(value: 0)
    let preparation = Task {
      try await MessageHTMLPresentation.prepare(body: body) { _ in
        sanitizationStarted.signal()
        allowSanitizationToFinish.wait()
        return SanitizedMessageHTML(documentHTML: "document")
      }
    }

    sanitizationStarted.wait()
    preparation.cancel()
    allowSanitizationToFinish.signal()

    do {
      _ = try await preparation.value
      XCTFail("Cancelled preparation should not publish a presentation")
    } catch is CancellationError {
    } catch {
      XCTFail("Expected cancellation, got \(error)")
    }
  }
}

extension MessageHTMLPresentationTests {
  func testReferencedInlineImagesHonorOverridingMaximumDimensions() {
    let contentIDs = MessageHTMLSanitizer.referencedInlineImageContentIDs(
      in: """
        <img src="cid:normal@example.com" style="max-width: 0; max-width: 600px">
        <img src="cid:important@example.com"
             style="max-height: 0; max-height: 600px !important">
        <img src="cid:hidden@example.com"
             style="max-width: 0 !important; max-width: 600px">
        """
    )

    XCTAssertEqual(contentIDs, ["normal@example.com", "important@example.com"])
  }

  func testSanitizerHonorsOverridingVisibilityAndOpacityDeclarations() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <div style="visibility: hidden; visibility: visible">Visible text</div>
        <div style="opacity: 0; opacity: 1 !important">
          <img src="https://images.example.com/visible.png">
        </div>
        <div style="visibility: hidden !important; visibility: visible">Hidden text</div>
        <div style="visibility: hidden!important; visibility: visible ! important">
          Visible spaced important text
        </div>
        <div style="visibility:/**/hidden">
          Comment-hidden text
          <img src="https://tracker.example/comment-hidden.png">
        </div>
        """
      )
    )

    XCTAssertTrue(result.documentHTML.contains("Visible text"))
    XCTAssertTrue(result.documentHTML.contains("Visible spaced important text"))
    XCTAssertFalse(result.documentHTML.contains("Hidden text"))
    XCTAssertFalse(result.documentHTML.contains("Comment-hidden text"))
    XCTAssertFalse(result.documentHTML.contains("comment-hidden.png"))
    XCTAssertEqual(
      result.remoteImageReferences.map(\.url.absoluteString),
      ["https://images.example.com/visible.png"]
    )
  }

  func testSanitizerStripsCommentsBeforeSplittingStyleDeclarations() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="display:/*;*/none">
          <img src="https://tracker.example/comment-delimiter.png">
        </div>
        """
      )
    )

    XCTAssertTrue(result.remoteImageReferences.isEmpty)
  }

  func testSanitizerPreservesVisibleDescendantsOfHiddenWrappers() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <div style="visibility: hidden">
          Hidden preview
          <span style="visibility: visible">Receipt</span>
          <span style="visibility: initial">Initial receipt</span>
          <span style="visibility: revert">Hidden reverted receipt</span>
          <img src="https://tracker.example/hidden.png">
          <span style="visibility: visible">
            <img src="https://images.example.com/visible.png">
          </span>
        </div>
        """
      )
    )

    XCTAssertFalse(result.documentHTML.contains("Hidden preview"))
    XCTAssertTrue(result.documentHTML.contains("Receipt"))
    XCTAssertTrue(result.documentHTML.contains("Initial receipt"))
    XCTAssertFalse(result.documentHTML.contains("Hidden reverted receipt"))
    XCTAssertFalse(result.documentHTML.contains("tracker.example"))
    XCTAssertEqual(
      result.remoteImageReferences.map(\.url.absoluteString),
      ["https://images.example.com/visible.png"]
    )
  }

  func testSanitizerDoesNotPromoteVisibleDescendantsOfCollapsedTableRows() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <table>
          <tr style="visibility: collapse">
            <td>
              <span style="visibility: visible">
                <img src="https://tracker.example/collapsed-row.png">
              </span>
            </td>
          </tr>
        </table>
        """
      )
    )

    XCTAssertTrue(result.remoteImageReferences.isEmpty)
    XCTAssertFalse(result.documentHTML.contains("collapsed-row.png"))
  }

  func testSanitizerDoesNotPromoteVisibleDescendantsOfCollapsedTableDisplay() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="display: table-row; visibility: collapse">
          <span style="visibility: visible">
            <img src="https://tracker.example/collapsed-row.png">
          </span>
        </div>
        """
      )
    )

    XCTAssertTrue(result.remoteImageReferences.isEmpty)
  }

  func testSanitizerPromotesVisibleDescendantsOfCollapsedNonTableElements() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <div style="visibility: collapse">
          <span style="visibility: visible">Receipt</span>
        </div>
        """
      )
    )

    XCTAssertTrue(result.documentHTML.contains("Receipt"))
  }

  func testSanitizerRemovesHiddenBranchesInsidePromotedVisibleSubtrees() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <div style="visibility: hidden">
          <span style="visibility: visible">
            Receipt
            <span style="visibility: hidden">
              Hidden details
              <img src="https://tracker.example/hidden.png">
            </span>
            <img src="https://images.example.com/visible.png">
          </span>
        </div>
        """
      )
    )

    XCTAssertTrue(result.documentHTML.contains("Receipt"))
    XCTAssertFalse(result.documentHTML.contains("Hidden details"))
    XCTAssertFalse(result.documentHTML.contains("tracker.example"))
    XCTAssertEqual(
      result.remoteImageReferences.map(\.url.absoluteString),
      ["https://images.example.com/visible.png"]
    )
  }

  func testSanitizerPromotesOnlyTopmostExplicitlyVisibleDescendant() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <div style="visibility: hidden">
          <span style="visibility: initial">
            <b style="visibility: visible">
              Receipt
              <img src="https://images.example.com/receipt.png">
            </b>
          </span>
        </div>
        """
      )
    )

    XCTAssertEqual(result.documentHTML.components(separatedBy: "Receipt").count - 1, 1)
    XCTAssertEqual(
      result.remoteImageReferences.map(\.url.absoluteString),
      ["https://images.example.com/receipt.png"]
    )
  }

  func testSanitizerDoesNotPromoteVisibleDescendantsOfOtherwiseHiddenWrappers() throws {
    for intermediateAttribute in [
      #"style="display: none""#,
      #"style="opacity: 0""#,
      #"style="width: 0""#,
      #"style="margin-left: -9999px""#,
      "hidden",
    ] {
      let result = try XCTUnwrap(
        MessageHTMLSanitizer.sanitize(
          """
          <p>Newsletter</p>
          <div style="visibility: hidden">
            <div \(intermediateAttribute)>
              <span style="visibility: visible">
                <img src="https://tracker.example/hidden.png">
              </span>
            </div>
          </div>
          """
        )
      )

      XCTAssertTrue(result.remoteImageReferences.isEmpty, intermediateAttribute)
    }
  }

  func testSanitizerHonorsPositiveMinimumOverZeroMaximum() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <div style="max-width: 0; min-width: 600px">
          Receipt
          <img src="https://images.example.com/receipt.png">
        </div>
        """
      )
    )

    XCTAssertTrue(result.documentHTML.contains("Receipt"))
    XCTAssertEqual(
      result.remoteImageReferences.map(\.url.absoluteString),
      ["https://images.example.com/receipt.png"]
    )
  }

  func testSanitizerHonorsPositiveMinimumOnZeroMaximumImage() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <img src="https://images.example.com/receipt.png"
             style="max-width: 0; min-width: 600px">
        """
      )
    )

    XCTAssertEqual(
      result.remoteImageReferences.map(\.url.absoluteString),
      ["https://images.example.com/receipt.png"]
    )
  }

  func testSanitizerIgnoresInvalidVisibilityAndOpacityOverrides() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="visibility: hidden; visibility: bogus">
          <img src="https://tracker.example/visibility.png">
        </div>
        <div style="opacity: 0; opacity: bogus">
          <img src="https://tracker.example/opacity.png">
        </div>
        """
      )
    )

    XCTAssertTrue(result.remoteImageReferences.isEmpty)
  }

  func testSanitizerHonorsCalculatedOpacityOverride() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="opacity: 0; opacity: calc(1)">
          <img src="https://images.example.com/visible.png">
        </div>
        """
      )
    )

    XCTAssertEqual(
      result.remoteImageReferences.map(\.url.absoluteString),
      ["https://images.example.com/visible.png"]
    )
  }

  func testSanitizerRemovesConstantCalculatedZeroOpacityContent() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="opacity: calc(1 - 1)">
          <img src="https://tracker.example/hidden.png">
        </div>
        """
      )
    )

    XCTAssertTrue(result.remoteImageReferences.isEmpty)
  }

  func testSanitizerRejectsNonCSSCalculatedOpacityOverrides() throws {
    for opacity in ["calc(nan)", "calc(infinity)", "calc(0x1p4)"] {
      let result = try XCTUnwrap(
        MessageHTMLSanitizer.sanitize(
          """
          <p>Newsletter</p>
          <div style="opacity:0;opacity:\(opacity)">
            <img src="https://tracker.example/hidden.png">
          </div>
          """
        )
      )

      XCTAssertTrue(result.remoteImageReferences.isEmpty, opacity)
    }
  }

  func testSanitizerRemovesConstantFunctionZeroOpacityContent() throws {
    for opacity in [
      "min(0, 0)", "max(0%, 0)", "clamp(0, 0%, 1)",
      "min(max(0, 0), 1)", "calc(min(0, 0))",
    ] {
      let result = try XCTUnwrap(
        MessageHTMLSanitizer.sanitize(
          """
          <p>Newsletter</p>
          <div style="opacity: \(opacity)">
            <img src="https://tracker.example/hidden.png">
          </div>
          """
        )
      )

      XCTAssertTrue(result.remoteImageReferences.isEmpty, opacity)
    }
  }

  func testSanitizerHonorsOverridingReadableHiddenDeclarations() throws {
    for style in [
      "display: none; display: block",
      "font-size: 0; font-size: 14px",
      "line-height: 0 !important; line-height: 1.5 !important",
      "margin: -9999px; margin: 0",
      "margin-left: -9999px; margin-left: 0 !important",
    ] {
      let result = try XCTUnwrap(
        MessageHTMLSanitizer.sanitize(#"<div style="\#(style)">Visible text</div>"#)
      )

      XCTAssertTrue(result.documentHTML.contains("Visible text"), style)
    }
  }

  func testSanitizerIgnoresInvalidReadableLengthOverrides() throws {
    for style in [
      "font-size: 0; font-size: bogus",
      "margin-left: -9999px; margin-left: bogus",
    ] {
      XCTAssertNil(
        try MessageHTMLSanitizer.sanitize(
          #"<div style="\#(style)">Hidden text</div>"#
        ),
        style
      )
    }
  }

  func testSanitizerIgnoresInvalidCompoundDisplayOverride() throws {
    XCTAssertNil(
      try MessageHTMLSanitizer.sanitize(
        #"<div style="display: none; display: none block">Hidden text</div>"#
      )
    )
  }

  func testSanitizerIgnoresStandaloneFlowDisplayOverride() throws {
    XCTAssertNil(
      try MessageHTMLSanitizer.sanitize(
        #"<div style="display: none; display: flow">Hidden text</div>"#
      )
    )
  }

  func testSanitizerPreservesVisibleContentWithInvalidZeroLengthOverride() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        #"<div style="height: 12px; height: 0abc">Visible text</div>"#
      )
    )

    XCTAssertTrue(result.documentHTML.contains("Visible text"))
  }

  func testSanitizerIgnoresInvalidMaximumDimensionOverrides() throws {
    for style in [
      "max-height: 0; max-height: normal",
      "max-width: 0; max-width: auto",
      "height: 0; height: 5",
    ] {
      let result = try XCTUnwrap(
        MessageHTMLSanitizer.sanitize(
          """
          <p>Newsletter</p>
          <img style="\(style)" src="https://tracker.example/hidden.png">
          """
        )
      )

      XCTAssertTrue(result.remoteImageReferences.isEmpty, style)
    }
  }

  func testSanitizerRemovesCalculatedZeroDimensionImages() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <img style="max-width: calc(0px + 0px)"
             src="https://tracker.example/hidden.png">
        """
      )
    )

    XCTAssertTrue(result.remoteImageReferences.isEmpty)
  }

  func testSanitizerHonorsOverridingMaximumDimensionDeclarations() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="max-width: 0; max-width: 600px">
          <img src="https://images.example.com/width.png">
        </div>
        <div style="max-height: 0; max-height: 600px !important">
          <img src="https://images.example.com/height.png">
        </div>
        """
      )
    )

    XCTAssertEqual(
      result.remoteImageReferences.map(\.url.absoluteString),
      ["https://images.example.com/width.png", "https://images.example.com/height.png"]
    )
  }

  func testSanitizerRetainsRemoteImageWithNonRenderingUnicodePreheader() throws {
    for text in ["&zwnj;", "&#847;"] {
      let result = try XCTUnwrap(
        MessageHTMLSanitizer.sanitize(
          """
          <div>\(text)</div>
          <img src="https://tracker.test/hero.png">
          """
        )
      )

      XCTAssertEqual(result.remoteImageReferences.count, 1)
    }
  }

  func testSanitizerRetainsRemoteImageWithOffCanvasMarginShorthandPreheader() throws {
    for style in ["margin: 0 -9999px", "margin: 0 0 -9999px", "margin: 0 0 0 -9999px"] {
      let result = try XCTUnwrap(
        MessageHTMLSanitizer.sanitize(
          """
          <div style="\(style)">Hidden preview</div>
          <img src="https://tracker.test/hero.png">
          """
        )
      )

      XCTAssertEqual(result.remoteImageReferences.count, 1)
    }
  }

  func testSanitizerChecksCancellationBetweenFullDocumentPasses() throws {
    var cancellationChecks = 0

    XCTAssertThrowsError(
      try MessageHTMLSanitizer.sanitize("<p>Readable</p>") {
        cancellationChecks += 1
        if cancellationChecks == 1 {
          throw CancellationError()
        }
      }
    ) { error in
      XCTAssertTrue(error is CancellationError)
    }
    XCTAssertEqual(cancellationChecks, 1)
  }

  func testSanitizerHandlesDeeplyNestedHiddenTextInOneTraversal() throws {
    let depth = 2_000
    let html =
      String(repeating: #"<div style="visibility: hidden">"#, count: depth)
      + "Hidden preview"
      + String(repeating: "</div>", count: depth)
      + #"<img src="https://images.example.com/hero.png">"#

    let result = try XCTUnwrap(MessageHTMLSanitizer.sanitize(html))

    XCTAssertFalse(result.documentHTML.contains("Hidden preview"))
    XCTAssertEqual(
      result.remoteImageReferences.map(\.url.absoluteString),
      ["https://images.example.com/hero.png"]
    )
  }
}

extension MessageHTMLPresentationTests {
  func testRemoteContentLoaderSkipsRequestsWhenPixelBudgetIsExhausted() async throws {
    let reference = RemoteMessageImageReference(
      identifier: "remote-image-0",
      url: try XCTUnwrap(URL(string: "https://images.example.com/hero.png"))
    )
    let presentation = SanitizedMessageHTML(
      documentHTML: #"<img data-unwired-remote-image="remote-image-0">"#,
      remoteImageReferences: [reference]
    )
    let loader = RemoteMessageContentLoader(
      maximumTotalPixelCount: 0,
      fetch: { _, _ in
        XCTFail("Pixel-exhausted content must not make a request")
        throw TestError.sanitizationFailed
      })

    let result = try await loader.load(presentation)

    XCTAssertEqual(result.loadedImageCount, 0)
    XCTAssertEqual(result.failedImageCount, 1)
  }
}

private func remoteContentTestPresentation() throws -> SanitizedMessageHTML {
  let body = MailboxMessageBody(
    text: "Newsletter",
    html: """
      <p>Newsletter</p>
      <img src="https://images.example.com/hero.png" alt="Hero">
      <img src="https://images.example.com/not-an-image" alt="Invalid">
      <img src="http://legacy.example.com/chart.jpg" alt="Legacy">
      """
  )
  guard case .html(let presentation) = MessageHTMLPresentation.resolve(body: body) else {
    throw TestError.sanitizationFailed
  }
  return presentation
}

private func remoteContentTransferBudgetResult(
  referenceCount: Int,
  fetch: @escaping RemoteMessageContentLoader.Fetch
) async throws -> (result: RemoteMessageContentLoadResult, requestedMaximumByteCounts: [Int]) {
  let references = try (0..<referenceCount).map {
    RemoteMessageImageReference(
      identifier: "remote-image-\($0)",
      url: try XCTUnwrap(URL(string: "https://images.example.com/image-\($0)"))
    )
  }
  let markers = references.map {
    #"<img data-unwired-remote-image="\#($0.identifier)">"#
  }.joined()
  var requestedMaximumByteCounts: [Int] = []
  let loader = RemoteMessageContentLoader(
    maximumTotalByteCount: 10,
    fetch: { request, maximumByteCount in
      requestedMaximumByteCounts.append(maximumByteCount)
      return try await fetch(request, maximumByteCount)
    }
  )
  let result = try await loader.load(
    SanitizedMessageHTML(
      documentHTML: "<html><body>\(markers)</body></html>",
      remoteImageReferences: references
    )
  )
  return (result, requestedMaximumByteCounts)
}

extension MessageHTMLPresentationTests {
  func testSanitizerHandlesBoundedNestedPercentageDimensionResolution() throws {
    let wrappers = String(
      repeating:
        #"<div style="width:100%;max-width:100%;min-width:100%;height:100%;max-height:100%;min-height:100%">"#,
      count: 32
    )
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        #"<p>Newsletter</p><div style="width:1px;height:1px">"# + wrappers
          + #"<img src="https://tracker.example/pixel.gif" style="width:100%;height:100%">"#
          + String(repeating: "</div>", count: 33)
      )
    )

    XCTAssertTrue(result.remoteImageReferences.isEmpty)
  }

  func testSanitizerRemovesConstantFunctionZeroDimensions() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <img style="width:min(0px, 0px)" src="https://tracker.example/pixel.gif">
        """
      )
    )

    XCTAssertTrue(result.remoteImageReferences.isEmpty)
  }

  func testSanitizerRemovesNestedConstantFunctionZeroDimensions() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <img style="width:calc(min(0px, 0px))" src="https://tracker.example/pixel.gif">
        """
      )
    )

    XCTAssertTrue(result.remoteImageReferences.isEmpty)
  }

  func testSanitizerDoesNotApplyTextIndentToRemoteImageBox() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <img style="text-indent:-100px" src="https://images.example.com/visible.png">
        """
      )
    )

    XCTAssertEqual(
      result.remoteImageReferences.map(\.url.absoluteString),
      ["https://images.example.com/visible.png"]
    )
  }

  func testSanitizerPromotesVisibleDescendantThroughRevertAncestor() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <div style="visibility:hidden"><span style="visibility:revert">
          <b style="visibility:visible">Receipt</b>
        </span></div>
        """
      )
    )

    XCTAssertTrue(result.documentHTML.contains("Receipt"))
  }

  func testSanitizerIgnoresMaximumDimensionsOnOrdinaryInlineElements() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(#"<span style="max-width:0;max-height:0">Receipt</span>"#)
    )

    XCTAssertTrue(result.documentHTML.contains("Receipt"))
  }

  func testSanitizerIgnoresDimensionsOnOrdinaryInlineElements() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        #"<p>Order <span style="width:0;height:0">Receipt</span>"#
          + #"<span style="display:initial;width:0">Initial receipt</span></p>"#
      )
    )

    XCTAssertTrue(result.documentHTML.contains("Receipt"))
    XCTAssertTrue(result.documentHTML.contains("Initial receipt"))
  }

  func testSanitizerTreatsDisplayContentsImagesAsHidden() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <img src="https://tracker.example/display-contents.png" style="display: contents">
        """
      )
    )

    XCTAssertTrue(result.remoteImageReferences.isEmpty)
    XCTAssertFalse(result.documentHTML.contains("display-contents.png"))
  }

  func testSanitizerResolvesPercentageDimensionsThroughInitialInlineDisplay() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="width:1px;height:1px">
          <span style="display:initial">
            <img src="https://tracker.example/pixel.gif" style="width:100%;height:100%">
          </span>
        </div>
        """
      )
    )

    XCTAssertTrue(result.remoteImageReferences.isEmpty)
  }

  func testSanitizerAccountsForAutoBlockMarginsInPercentageDimensions() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="width:3px">
          <div style="margin:0 1px">
            <img src="https://tracker.example/pixel.gif" style="width:100%;height:1px">
          </div>
        </div>
        """
      )
    )

    XCTAssertTrue(result.remoteImageReferences.isEmpty)
  }

  func testSanitizerAccountsForAutoBlockBordersInPercentageDimensions() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="width:3px">
          <div style="border-left:1px solid;border-right:1px solid">
            <img src="https://tracker.example/pixel.gif" style="width:100%;height:1px">
          </div>
        </div>
        """
      )
    )

    XCTAssertTrue(result.remoteImageReferences.isEmpty)
  }

  func testSanitizerAccountsForDefaultBorderWidthsInPercentageDimensions() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="width:7px">
          <div style="border-left:solid;border-right:solid">
            <img src="https://tracker.example/default-border.gif"
                 style="width:100%;height:1px">
          </div>
        </div>
        """
      )
    )

    XCTAssertTrue(result.remoteImageReferences.isEmpty)
    XCTAssertFalse(result.documentHTML.contains("default-border.gif"))
  }

  func testSanitizerAccountsForNamedBorderColorsInPercentageDimensions() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="width:7px">
          <div style="border-left:solid rebeccapurple;border-right:solid rebeccapurple">
            <img src="https://tracker.example/named-border.gif"
                 style="width:100%;height:1px">
          </div>
        </div>
        """
      )
    )

    XCTAssertTrue(result.remoteImageReferences.isEmpty)
    XCTAssertFalse(result.documentHTML.contains("named-border.gif"))
  }

  func testSanitizerAccountsForSystemBorderColorsInPercentageDimensions() throws {
    for color in ["accentcolor", "canvastext", "linktext"] {
      let result = try XCTUnwrap(
        MessageHTMLSanitizer.sanitize(
          """
          <p>Newsletter</p>
          <div style="width:7px">
            <div style="border-left:solid \(color);border-right:solid \(color)">
              <img src="https://tracker.example/system-border.gif"
                   style="width:100%;height:1px">
            </div>
          </div>
          """
        )
      )

      XCTAssertTrue(result.remoteImageReferences.isEmpty, color)
      XCTAssertFalse(result.documentHTML.contains("system-border.gif"), color)
    }
  }

  func testSanitizerIgnoresInvalidBorderShorthandsInPercentageDimensions() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="width:7px">
          <div style="border-left:solid bogus;border-right:solid bogus">
            <img src="https://images.example/visible.gif"
                 style="width:100%;height:1px">
          </div>
        </div>
        """
      )
    )

    XCTAssertEqual(result.remoteImageReferences.count, 1)
    XCTAssertEqual(
      result.remoteImageReferences.first?.url.absoluteString,
      "https://images.example/visible.gif"
    )
    XCTAssertTrue(result.documentHTML.contains(RemoteMessageContentMarkup.attribute))
    XCTAssertFalse(result.documentHTML.contains("visible.gif"))
  }

  func testSanitizerIgnoresInvalidFunctionalBorderColorsInPercentageDimensions() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="width:7px">
          <div style="border-left:solid rgb(bogus);border-right:solid rgb(bogus)">
            <img src="https://images.example/visible-functional-color.gif"
                 style="width:100%;height:1px">
          </div>
        </div>
        """
      )
    )

    XCTAssertEqual(
      result.remoteImageReferences.map(\.url.absoluteString),
      ["https://images.example/visible-functional-color.gif"]
    )
  }

  func testSanitizerResetsOmittedBorderStyleInLaterShorthand() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="width:601px">
          <div style="border-left-style:solid;border-left:300px;
                      border-right-style:solid;border-right:300px">
            <img src="https://images.example/visible-reset-border.gif"
                 style="width:100%;height:1px">
          </div>
        </div>
        """
      )
    )

    XCTAssertEqual(
      result.remoteImageReferences.map(\.url.absoluteString),
      ["https://images.example/visible-reset-border.gif"]
    )
  }

  func testSanitizerResolvesInheritedTrackingPixelDimensions() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="width:1px;height:1px">
          <img src="https://tracker.example/inherited.gif"
               style="width:inherit;height:inherit">
        </div>
        """
      )
    )

    XCTAssertTrue(result.remoteImageReferences.isEmpty)
    XCTAssertFalse(result.documentHTML.contains("inherited.gif"))
  }

  func testSanitizerAccountsForFontRelativeInsetsInPercentageDimensions() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="width:33px">
          <div style="font-size:16px;padding:0 1em">
            <img src="https://tracker.example/font-relative-inset.gif"
                 style="width:100%;height:1px">
          </div>
        </div>
        """
      )
    )

    XCTAssertTrue(result.remoteImageReferences.isEmpty)
    XCTAssertFalse(result.documentHTML.contains("font-relative-inset.gif"))
  }

  func testSanitizerAccountsForKeywordBorderWidthsInPercentageDimensions() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="width:11px">
          <div style="border-left:thick solid;border-right:thick solid">
            <img src="https://tracker.example/keyword-border.gif"
                 style="width:100%;height:1px">
          </div>
        </div>
        """
      )
    )

    XCTAssertTrue(result.remoteImageReferences.isEmpty)
    XCTAssertFalse(result.documentHTML.contains("keyword-border.gif"))
  }

  func testSanitizerIgnoresInactiveBorderWidthsInPercentageDimensions() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="width:601px">
          <div style="border-left-width:300px;border-right-width:300px">
            <img src="https://images.example.com/inactive-border.png"
                 style="width:100%;height:1px">
          </div>
        </div>
        """
      )
    )

    XCTAssertEqual(
      result.remoteImageReferences.map(\.url.absoluteString),
      ["https://images.example.com/inactive-border.png"]
    )
  }

  func testSanitizerRejectsNegativeBorderWidthOverrides() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="width:3px">
          <div style="border-left:1px solid;border-right:1px solid;
                      border-left-width:-1px;border-right-width:-1px">
            <img src="https://tracker.example/negative-border.gif"
                 style="width:100%;height:1px">
          </div>
        </div>
        """
      )
    )

    XCTAssertTrue(result.remoteImageReferences.isEmpty)
    XCTAssertFalse(result.documentHTML.contains("negative-border.gif"))
  }

  func testSanitizerIgnoresInvalidNegativePaddingOverride() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="width:301px">
          <div style="padding-left:300px;padding-left:-300px">
            <img src="https://tracker.example/negative-padding.gif"
                 style="width:100%;height:1px">
          </div>
        </div>
        """
      )
    )

    XCTAssertTrue(result.remoteImageReferences.isEmpty)
    XCTAssertFalse(result.documentHTML.contains("negative-padding.gif"))
  }

  func testSanitizerIncludesAncestorPaddingWhenEvaluatingNegativeOffsets() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="padding-left:200px">
          <span>
            <img src="https://images.example.com/visible.png" style="margin-left:-100px">
          </span>
        </div>
        """
      )
    )

    XCTAssertEqual(
      result.remoteImageReferences.map(\.url.absoluteString),
      ["https://images.example.com/visible.png"]
    )
  }

  func testSanitizerRejectsCalculatedDimensionsWithoutOperatorWhitespace() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p><img src="https://images.example.com/hero.png"
          style="width:600px;width:calc(1px+0px);height:600px;height:calc(1px+0px)">
        <img src="https://images.example.com/banner.png"
          style="width:600px;width:calc(0px+0px);height:600px;height:calc(0px+0px)">
        """
      )
    )

    XCTAssertEqual(
      result.remoteImageReferences.map(\.url.absoluteString),
      ["https://images.example.com/hero.png", "https://images.example.com/banner.png"]
    )
  }
}

private enum TestError: Error {
  case sanitizationFailed
}

private final class PartialFailureURLProtocol: URLProtocol, @unchecked Sendable {
  static let data = Data([1, 2, 3])
  static let startSignal = URLProtocolStartSignal()

  // swiftlint:disable:next static_over_final_class
  override class func canInit(with _: URLRequest) -> Bool { true }

  // swiftlint:disable:next static_over_final_class
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.startSignal.signal()
  }

  override func stopLoading() {}
}

private final class URLProtocolStartSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var started = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func reset() {
    lock.withLock {
      started = false
      precondition(waiters.isEmpty)
    }
  }

  func waitUntilStarted() async {
    await withCheckedContinuation { continuation in
      let shouldResume = lock.withLock {
        if started { return true }
        waiters.append(continuation)
        return false
      }
      if shouldResume {
        continuation.resume()
      }
    }
  }

  func signal() {
    let pendingWaiters = lock.withLock {
      started = true
      let pendingWaiters = waiters
      waiters.removeAll()
      return pendingWaiters
    }
    for waiter in pendingWaiters {
      waiter.resume()
    }
  }
}

@MainActor
private final class MessageHTMLTestNavigationDelegate: NSObject, WKNavigationDelegate {
  let errorExpectation: XCTestExpectation
  var error: Error?

  init(expectation: XCTestExpectation) {
    errorExpectation = expectation
  }

  func webView(_: WKWebView, didFinish _: WKNavigation!) {
    errorExpectation.fulfill()
  }

  func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
    self.error = error
    errorExpectation.fulfill()
  }
}
