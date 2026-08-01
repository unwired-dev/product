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

  func testSanitizerBlocksRemoteImagesInsideZeroMaximumDimensionWrappers() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="max-width: 0">
          <img src="https://tracker.example/width-pixel.gif">
        </div>
        <div style="max-height: 0">
          <img src="https://tracker.example/height-pixel.gif">
        </div>
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

  func testSanitizerRemovesRemoteImagesInsideSignedZeroWrappers() throws {
    let result = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <div style="max-width: +0px">
          <img src="https://tracker.example/wrapped.gif">
        </div>
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
    var currentDate = Date(timeIntervalSinceReferenceDate: 0)
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
      now: { currentDate },
      fetch: { request, _ in
        requestedURLs.append(try XCTUnwrap(request.url))
        XCTAssertEqual(request.timeoutInterval, 30)
        currentDate.addTimeInterval(31)
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
        """
      )
    )

    XCTAssertTrue(result.documentHTML.contains("Visible text"))
    XCTAssertFalse(result.documentHTML.contains("Hidden text"))
    XCTAssertEqual(
      result.remoteImageReferences.map(\.url.absoluteString),
      ["https://images.example.com/visible.png"]
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
      "height: 0; height: 5",
    ] {
      let result = try XCTUnwrap(
        MessageHTMLSanitizer.sanitize(
          """
          <p>Newsletter</p>
          <div style="\(style)">
            <img src="https://tracker.example/hidden.png">
          </div>
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
        <div style="max-width: calc(0px + 0px)">
          <img src="https://tracker.example/hidden.png">
        </div>
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
