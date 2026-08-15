import Foundation
import Testing
import WebKit

@testable import unwired_mail

private struct RemoteImageDeduplicationCase: CustomTestStringConvertible, Sendable {
  let name: String
  let html: String
  let expectedURL: String
  let referenceCount: Int

  var testDescription: String { name }
}

private let remoteImageDeduplicationCases = [
  RemoteImageDeduplicationCase(
    name: "scheme, host, fragment, and default port",
    html: """
      <p>Newsletter</p>
      <img src="HTTPS://images.example.com/hero.png" alt="Uppercase scheme hero">
      <img src="https://IMAGES.EXAMPLE.COM/hero.png#one" alt="Hero">
      <img src="https://images.example.com/hero.png#two" alt="Repeated hero">
      <img src="https://images.example.com:443/hero.png" alt="Default port hero">
      """,
    expectedURL: "https://images.example.com/hero.png",
    referenceCount: 4
  ),
  RemoteImageDeduplicationCase(
    name: "empty and slash paths",
    html: """
      <img src="https://images.example.com" alt="Empty path">
      <img src="https://images.example.com/" alt="Slash path">
      """,
    expectedURL: "https://images.example.com/",
    referenceCount: 2
  ),
  RemoteImageDeduplicationCase(
    name: "percent-escape hex casing",
    html: """
      <img src="https://images.example.com/%2fhero.png?token=%ab" alt="Lowercase escapes">
      <img src="https://images.example.com/%2Fhero.png?token=%AB" alt="Uppercase escapes">
      """,
    expectedURL: "https://images.example.com/%2Fhero.png?token=%AB",
    referenceCount: 2
  ),
  RemoteImageDeduplicationCase(
    name: "percent-encoded unreserved characters",
    html: """
      <img src="https://images.example.com/%70ixel.png" alt="Encoded path">
      <img src="https://images.example.com/pixel.png" alt="Literal path">
      """,
    expectedURL: "https://images.example.com/pixel.png",
    referenceCount: 2
  ),
  RemoteImageDeduplicationCase(
    name: "normalized dot segments",
    html: """
      <img src="https://tracker.example/a/../pixel" alt="Literal dot segments">
      <img src="https://tracker.example/a/%2e%2e/pixel" alt="Encoded dot segments">
      <img src="https://tracker.example/pixel" alt="Normalized path">
      """,
    expectedURL: "https://tracker.example/pixel",
    referenceCount: 3
  ),
]

// swiftlint:disable file_length

@Suite(.serialized)
final class MessageHTMLPresentationTests {
  @Test
  func testSanitizerPreservesCommonEmailLayoutAndSafeStyles() throws {
    let result = try requireValue(
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
      ))

    #expect(result.documentHTML.contains("<table"))
    #expect(result.documentHTML.contains("width=\"100%\""))
    #expect(result.documentHTML.contains("cellpadding=\"8\""))
    #expect(result.documentHTML.contains("border-collapse:collapse"))
    #expect(result.documentHTML.contains("font-weight:bold"))
    #expect(!(result.documentHTML.contains("background-image")))
    #expect(result.documentHTML.contains("<strong>Receipt</strong>"))
  }

  @Test
  func testSanitizerRemovesActiveContentUnsafeURLsAndRemoteImageSources() throws {
    let result = try requireValue(
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
      ))
    let sanitized = result.documentHTML.lowercased()

    for forbidden in [
      "http-equiv=\"refresh\"", "<script", "<form", "<input", "<iframe", "<object", "onclick",
      "javascript:", "onerror", "tracker.test",
    ] {
      #expect(!(sanitized.contains(forbidden)), "Unexpected active content: \(forbidden)")
    }
    #expect(sanitized.contains("safe text"))
    #expect(sanitized.contains(">unsafe link</a>"))
    #expect(sanitized.contains("href=\"https://example.com/path\""))
    #expect(sanitized.contains("<img"))
    #expect(sanitized.contains("alt=\"receipt\""))
    #expect(sanitized.contains("width=\"1\""))
  }

  @Test
  func testSanitizerRecordsRemoteImagesWithoutExposingTheirURLsToWebKit() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <img src="https://images.example.com/hero.png" alt="Hero">
        <img src="http://legacy.example.com/chart.jpg" alt="Chart">
        <img src="cid:logo@example.com" alt="Logo">
        """
      ))

    #expect(
      result.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/hero.png"
      ])
    #expect(result.remoteImageReferences.map(\.identifier) == ["remote-image-0"])
    #expect(
      result.documentHTML.contains(
        "data-unwired-remote-image=\"remote-image-0\""
      ))
    #expect(!(result.documentHTML.contains("remote-image-1")))
    #expect(!(result.documentHTML.contains("images.example.com")))
    #expect(!(result.documentHTML.contains("legacy.example.com")))
    #expect(result.documentHTML.contains("src=\"cid:logo@example.com\""))
  }

  @Test
  func testSanitizerIgnoresSpoofedRemoteImageMarkersAndCredentialedURLs() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <img data-unwired-remote-image="remote-image-9" alt="Spoofed">
        <img src="https://user:secret@example.com/private.png" alt="Credentialed">
        """
      ))

    #expect(result.remoteImageReferences.isEmpty)
    #expect(!(result.documentHTML.contains("data-unwired-remote-image")))
    #expect(!(result.documentHTML.contains("secret")))
  }

  @Test
  func testSanitizerAllowsOnlyExplicitLinkSchemes() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <a href="https://example.com">Web</a>
        <a href="mailto:person@example.com">Mail</a>
        <a href="tel:+420123456789">Phone</a>
        <a href="ftp://example.com/file">FTP</a>
        <a href="/relative">Relative</a>
        """
      ))

    #expect(result.documentHTML.contains("href=\"https://example.com\""))
    #expect(result.documentHTML.contains("href=\"mailto:person@example.com\""))
    #expect(result.documentHTML.contains("href=\"tel:+420123456789\""))
    #expect(!(result.documentHTML.contains("ftp://")))
    #expect(!(result.documentHTML.contains("href=\"/relative\"")))
  }

  @Test
  func testSanitizerHandlesMalformedMarkupAndRejectsEmptyActiveContent() throws {
    let malformed = try requireValue(MessageHTMLSanitizer.sanitize("<table><tr><td><b>Readable"))

    #expect(malformed.documentHTML.contains("<b>Readable</b>"))
    #expect(
      try MessageHTMLSanitizer.sanitize("<script>alert('only active content')</script>") == nil)
    #expect(try MessageHTMLSanitizer.sanitize(" \n\t ") == nil)
  }

  @Test
  func testSanitizerRetainsImageOnlyCIDContent() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        #"<img src="cid:barcode@example.com" alt="Barcode">"#
      ))

    #expect(result.documentHTML.contains("src=\"cid:barcode@example.com\""))
  }

  @Test
  func testReferencedInlineImagesIgnoreWhitespacePaddedZeroDimensions() {
    let contentIDs = MessageHTMLSanitizer.referencedInlineImageContentIDs(
      in: """
        <img src="cid:zero-width@example.com" width=" 0 ">
        <img src="cid:zero-height@example.com" height="\n0px\t">
        <img src="cid:zero-max-width@example.com" style="max-width: .0px !important">
        <img src="cid:visible@example.com">
        """
    )

    #expect(contentIDs == ["visible@example.com"])
  }

  @Test
  func testSanitizerRetainsCIDImageInsideZeroLineHeightContainer() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Receipt</p>
        <div style="line-height: 0"><img src="cid:logo@example.com" alt="Logo"></div>
        """
      ))

    #expect(result.documentHTML.contains("src=\"cid:logo@example.com\""))
  }

  @Test
  func testSanitizerRetainsCIDImageInsideZeroFontSizeContainer() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Receipt</p>
        <div style="font-size: 0"><img src="cid:logo@example.com" alt="Logo"></div>
        """
      ))

    #expect(result.documentHTML.contains("src=\"cid:logo@example.com\""))
  }

  @Test
  func testSanitizerRetainsRemoteImageWithHiddenPreheaderText() throws {
    for hiddenAttribute in [
      "hidden",
      "style=\"display: none !important\"",
      "style=\"visibility: hidden\"",
    ] {
      let result = try requireValue(
        MessageHTMLSanitizer.sanitize(
          """
          <div \(hiddenAttribute)>Hidden preview</div>
          <img src="https://tracker.test/hero.png">
          """
        ))

      #expect(result.remoteImageReferences.count == 1)
      #expect(!(result.documentHTML.contains("Hidden preview")))
    }
  }

  @Test
  func testSanitizerRetainsRemoteImageWithCSSHiddenPreheaderText() throws {
    for style in [
      "opacity: 0%", "opacity: -0.1", "font-size: 0", "height: 0px", "width: 0%",
      "line-height: 0.0em !important", "text-indent: -9999px", "margin: -9999px",
      "margin-left: -9999px", "margin-right: -9999px", "margin-top: -9999px",
    ] {
      let result = try requireValue(
        MessageHTMLSanitizer.sanitize(
          """
          <div style="\(style)">Hidden preview</div>
          <img src="https://tracker.test/hero.png">
          """
        ))

      #expect(result.remoteImageReferences.count == 1)
    }
  }

  @Test
  func testSanitizerBlocksRemoteImagesWithZeroMaximumDimensions() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <img style="max-width: 0" src="https://tracker.example/width-pixel.gif">
        <img style="max-height: 0" src="https://tracker.example/height-pixel.gif">
        <img src="https://images.example.com/hero.png">
        """
      ))

    #expect(
      result.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/hero.png"
      ])
    #expect(!(result.documentHTML.contains("tracker.example")))
  }

  @Test
  func testSanitizerPreservesContentWithSmallNegativeLayoutOffsets() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <div style="margin-top: -1px">
          Visible details
        </div>
        """
      ))

    #expect(result.documentHTML.contains("Visible details"))
  }

  @Test
  func testSanitizedDocumentUsesRestrictiveContentSecurityPolicy() throws {
    let result = try requireValue(MessageHTMLSanitizer.sanitize("<p>Hello</p>"))

    #expect(result.documentHTML.contains("default-src 'none'"))
    #expect(result.documentHTML.contains("img-src data:"))
    #expect(result.documentHTML.contains("connect-src 'none'"))
    #expect(result.documentHTML.contains("frame-src 'none'"))
    #expect(result.documentHTML.contains("object-src 'none'"))
    #expect(result.documentHTML.contains("base-uri 'none'"))
    #expect(result.documentHTML.contains("form-action 'none'"))
    #expect(result.documentHTML.contains("<p>Hello</p>"))
  }
}

extension MessageHTMLPresentationTests {
  @Test
  func testSanitizerRetainsRemoteImageOnlyMessagesForConsent() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        #"<img src="https://images.example.com/receipt.png" alt="Receipt">"#
      ))

    #expect(
      result.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/receipt.png"
      ])
    #expect(result.documentHTML.contains("data-unwired-remote-image"))
  }

  @Test
  func testSanitizerIgnoresNonRenderingTextInRemoteImageOnlyMessages() throws {
    for nonRenderingElement in [
      "<style>img { display: block; }</style>",
      "<script>document.body.dataset.loaded = 'true';</script>",
    ] {
      let result = try requireValue(
        MessageHTMLSanitizer.sanitize(
          nonRenderingElement + #"<img src="https://images.example.com/receipt.png">"#
        ))

      #expect(
        result.remoteImageReferences.map(\.url.absoluteString) == [
          "https://images.example.com/receipt.png"
        ])
    }
  }

  @Test
  func testSanitizerExcludesInvisibleRemoteImagesAndDeduplicatesURLs() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <img src="https://tracker.example/pixel.gif" width="0" alt="Tracker">
        <img src="https://images.example.com/hero.png" alt="Hero">
        <img src="https://images.example.com/hero.png" alt="Repeated hero">
        """
      ))

    #expect(
      result.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/hero.png"
      ])
    #expect(
      result.documentHTML.components(
        separatedBy: #"data-unwired-remote-image="remote-image-0""#
      ).count - 1 == 2)
    #expect(!(result.documentHTML.contains("tracker.example")))
    #expect(!(result.documentHTML.contains(#"alt="Tracker" src="#)))
  }

  @Test(arguments: remoteImageDeduplicationCases)
  fileprivate func sanitizerDeduplicatesRequestEquivalentRemoteImageURLs(
    _ testCase: RemoteImageDeduplicationCase
  ) throws {
    let result = try requireValue(MessageHTMLSanitizer.sanitize(testCase.html))

    #expect(result.remoteImageReferences.map(\.url.absoluteString) == [testCase.expectedURL])
    #expect(
      result.documentHTML.components(
        separatedBy: #"data-unwired-remote-image="remote-image-0""#
      ).count - 1 == testCase.referenceCount)
  }

  @Test
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
      Issue.record("Expected sanitized HTML")
      return
    }

    #expect(
      presentation.documentHTML.contains(
        "src=\"data:image/png;base64,\(imageData.base64EncodedString())\""
      ))
    #expect(!(presentation.documentHTML.lowercased().contains("cid:")))
  }

  @Test
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
      Issue.record("Expected sanitized HTML")
      return
    }

    let dataSource = "src=\"data:image/png;base64,"
    #expect(presentation.documentHTML.components(separatedBy: dataSource).count - 1 == 4)
    #expect(presentation.documentHTML.components(separatedBy: "alt=\"Repeated\"").count - 1 == 5)
    #expect(!(presentation.documentHTML.lowercased().contains("cid:")))
  }

  @Test
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
      Issue.record("Expected sanitized HTML")
      return
    }

    #expect(presentation.documentHTML.contains("alt=\"Missing image\""))
    #expect(presentation.documentHTML.contains("alt=\"Remote image\""))
    #expect(!(presentation.documentHTML.lowercased().contains("cid:")))
    #expect(!(presentation.documentHTML.contains("tracker.example")))
    #expect(!(presentation.documentHTML.contains("<img src=")))
  }

  @Test
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
      Issue.record("Expected sanitized HTML")
      return
    }

    #expect(
      presentation.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/logo.png"
      ])
    #expect(!(presentation.documentHTML.contains("tracker.example")))
  }

  @Test
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
      Issue.record("Expected sanitized HTML")
      return
    }

    #expect(
      presentation.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/minimum-width.png",
        "https://images.example.com/calculated-size.png",
        "https://images.example.com/logo.png",
      ])
    #expect(!(presentation.documentHTML.contains("tracker.example")))
    #expect(!(presentation.documentHTML.contains("max-width.gif")))
    #expect(!(presentation.documentHTML.contains("max-height.gif")))
    #expect(!(presentation.documentHTML.contains("signed-one.gif")))
    #expect(!(presentation.documentHTML.contains("signed-zero.gif")))
    #expect(!(presentation.documentHTML.contains("calculated-one.gif")))
    #expect(!(presentation.documentHTML.contains("calculated-subtraction.gif")))
    #expect(!(presentation.documentHTML.contains("point-one.gif")))
    #expect(!(presentation.documentHTML.contains("font-relative-one.gif")))
  }

  @Test
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
      Issue.record("Expected sanitized HTML")
      return
    }

    #expect(presentation.remoteImageReferences.isEmpty)
    #expect(!(presentation.documentHTML.contains("root-font-relative-one.gif")))
  }

  @Test
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
      Issue.record("Expected sanitized HTML")
      return
    }

    #expect(
      presentation.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/hero.png",
        "https://images.example.com/percentage-minimum.png",
      ])
    #expect(!(presentation.documentHTML.contains("percentage.gif")))
    #expect(!(presentation.documentHTML.contains("nested-percentage.gif")))
    #expect(!(presentation.documentHTML.contains("inline-ancestor-percentage.gif")))
    #expect(!(presentation.documentHTML.contains("constrained-percentage.gif")))
  }

  @Test
  func testSanitizerResolvesCalculatedPercentageTrackingPixelsAgainstContainingBlock() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="width:100px">
          <img src="https://tracker.example/calculated-percentage.gif"
               style="width:calc(1% + 0px);height:1px">
        </div>
        """
      ))

    #expect(result.remoteImageReferences.isEmpty)
    #expect(!(result.documentHTML.contains("calculated-percentage.gif")))
  }

  @Test
  func testSanitizerResolvesPercentageWidthThroughAutoSizedBlock() throws {
    let result = try requireValue(
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
      ))

    #expect(result.remoteImageReferences.isEmpty)
    #expect(!(result.documentHTML.contains("auto-block-percentage.gif")))
  }

  @Test
  func testSanitizerIgnoresStrippedPositioningWhenResolvingPercentageWidth() throws {
    let result = try requireValue(
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
      ))

    #expect(result.remoteImageReferences.isEmpty)
    #expect(!(result.documentHTML.contains("stripped-position.gif")))
  }

  @Test
  func testSanitizerResolvesPercentageWidthThroughExplicitBlockSpan() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <span style="display: block; width: 1px; height: 1px">
          <img src="https://tracker.example/block-span-percentage.gif"
               style="width: 100%; height: 100%">
        </span>
        """
      ))

    #expect(result.remoteImageReferences.isEmpty)
    #expect(!(result.documentHTML.contains("block-span-percentage.gif")))
  }

  @Test
  func testSanitizerAppliesMaximumToAutoBlockWidth() throws {
    let result = try requireValue(
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
      ))

    #expect(result.remoteImageReferences.isEmpty)
    #expect(!(result.documentHTML.contains("constrained-auto-block.gif")))
  }

  @Test
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
      Issue.record("Expected sanitized HTML")
      return
    }

    #expect(
      presentation.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/spaced-important.png"
      ])
  }

  @Test
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
      Issue.record("Expected sanitized HTML")
      return
    }

    #expect(
      presentation.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/relative-minimum.png"
      ])
    #expect(!(presentation.documentHTML.contains("initial-font-size.gif")))
  }

  @Test
  func testSanitizerAcceptsFontSizeKeywordOverridesForRelativeImageDimensions() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <img src="https://images.example.com/medium-font-size.png"
             style="font-size:1px;font-size:medium;width:1em;height:1em">
        <img src="https://images.example.com/larger-font-size.png"
             style="font-size:1px;font-size:larger;width:1em;height:1em">
        <img src="https://images.example.com/smaller-font-size.png"
             style="font-size:1px;font-size:smaller;width:1em;height:1em">
        """
      ))

    #expect(
      result.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/medium-font-size.png",
        "https://images.example.com/larger-font-size.png",
        "https://images.example.com/smaller-font-size.png",
      ])
  }

  @Test
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
      Issue.record("Expected sanitized HTML")
      return
    }

    #expect(
      presentation.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/logo.png"
      ])
    #expect(!(presentation.documentHTML.contains("inherited-font-relative-one.gif")))
    #expect(!(presentation.documentHTML.contains("nested-font-relative-one.gif")))
  }

  @Test
  func testSanitizerBlocksFontRelativeTrackingPixelWithUnitlessZeroFontSize() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <img src="https://tracker.example/unitless-zero-font.gif"
             style="font-size:0;width:1em;height:1em">
        """
      ))

    #expect(result.remoteImageReferences.isEmpty)
    #expect(!(result.documentHTML.contains("unitless-zero-font.gif")))
  }

  @Test
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
      Issue.record("Expected sanitized HTML")
      return
    }

    #expect(
      presentation.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/point-minimum.png",
        "https://images.example.com/minimum-height.png",
      ])
    #expect(!(presentation.documentHTML.contains("tracker.example")))
    #expect(presentation.documentHTML.contains("min-height:600px"))
  }

  @Test
  func testSanitizerDoesNotRetainRemoteImagesInsideOffCanvasWrappers() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="margin-left: -9999px">
          <img src="https://tracker.example/off-canvas.gif">
        </div>
        <img src="https://images.example.com/logo.png">
        """
      ))

    #expect(
      result.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/logo.png"
      ])
    #expect(
      !(result.documentHTML.contains(RemoteMessageContentMarkup.attribute + "=\"remote-image-0\"")))
  }

  @Test
  func testSanitizerDoesNotRetainRemoteImagesInsideCalculatedOffCanvasWrappers() throws {
    for style in [
      "margin: calc(-9999px)", "text-indent: calc(-9999px)", "margin-left: -99in",
      "margin-left: min(-9999px, -100px)", "margin-left: max(-9999px, -100px)",
      "margin-left: clamp(-9999px, -500px, -100px)",
    ] {
      let result = try requireValue(
        MessageHTMLSanitizer.sanitize(
          """
          <p>Newsletter</p>
          <div style="\(style)">
            <img src="https://tracker.example/off-canvas.gif">
          </div>
          <img src="https://images.example.com/logo.png">
          """
        ))

      #expect(
        result.remoteImageReferences.map(\.url.absoluteString) == [
          "https://images.example.com/logo.png"
        ], Comment(rawValue: style))
      #expect(
        !(result.documentHTML.contains("off-canvas.gif")),
        Comment(rawValue: style)
      )
    }
  }

  @Test
  func testSanitizerRetainsRemoteImagesOffsetByKnownPrecedingFlow() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <div style="height:200px">Spacer</div>
        <div style="margin-top:-100px">
          <img src="https://images.example.com/visible.png">
        </div>
        """
      ))

    #expect(
      result.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/visible.png"
      ])
  }

  @Test
  func testSanitizerRetainsRemoteImagesOffsetByPrecedingBoxModel() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <div style="height:1px;padding-bottom:100px"></div>
        <div style="margin-top:-100px">
          <img src="https://images.example.com/visible.png">
        </div>
        """
      ))

    #expect(
      result.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/visible.png"
      ])
  }

  @Test
  func testSanitizerRetainsRemoteImagesOffsetByIntrinsicPrecedingFlow() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <div>
          Line one<br>Line two<br>Line three<br>Line four<br>Line five<br>Line six
        </div>
        <div style="margin-top:-100px">
          <img src="https://images.example.com/visible.png">
        </div>
        """
      ))

    #expect(
      result.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/visible.png"
      ])
  }

  @Test
  func testSanitizerIgnoresNonBoxGeneratingPrecedingFlowHeights() throws {
    for display in ["inline", "contents"] {
      let result = try requireValue(
        MessageHTMLSanitizer.sanitize(
          """
          <span style="display:\(display);height:200px">Spacer</span>
          <div style="margin-top:-100px">
            <img src="https://tracker.example/off-canvas.gif">
          </div>
          """
        ))

      #expect(result.remoteImageReferences.isEmpty, Comment(rawValue: display))
      #expect(
        !(result.documentHTML.contains("off-canvas.gif")),
        Comment(rawValue: display)
      )
    }
  }

  @Test
  func testSanitizerUsesDefaultInlineDisplayForPrecedingFlowHeights() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p style="height:1px">Newsletter</p>
        <span style="height:200px"></span>
        <div style="margin-top:-100px">
          <img src="https://tracker.example/off-canvas-default-inline.gif">
        </div>
        """
      ))

    #expect(result.remoteImageReferences.isEmpty)
    #expect(!(result.documentHTML.contains("off-canvas-default-inline.gif")))
  }

  @Test
  func testSanitizerRetainsRemoteImagesInsideNonOffsettingNegativeMargins() throws {
    let result = try requireValue(
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
      ))

    #expect(
      result.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/right-margin.png",
        "https://images.example.com/bottom-margin.png",
      ])
  }

  @Test
  func testSanitizerPreservesImagesWithUnresolvedPercentageOffsets() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <div style="width:1px">
          <img src="https://images.example.com/visible.png"
               style="margin-left:-100%;min-width:600px">
        </div>
        """
      ))

    #expect(
      result.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/visible.png"
      ])
  }

  @Test
  func testSanitizerRetainsRemoteImageOffsetBackIntoViewport() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <div style="padding-left: 200px">
          <img style="margin-left: -100px" src="https://images.example.com/hero.png">
        </div>
        """
      ))

    #expect(
      result.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/hero.png"
      ])
  }

  @Test
  func testSanitizerRetainsIndentedRemoteImageOffsetByContainerPadding() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <div style="padding-left:200px;text-indent:-100px">
          <img src="https://images.example.com/hero.png">
        </div>
        """
      ))

    #expect(
      result.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/hero.png"
      ])
  }

  @Test
  func testSanitizerRetainsOverflowFromZeroSizedContainer() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <div style="width: 0">
          <img style="width: 600px; height: 100px" src="https://images.example.com/hero.png">
        </div>
        """
      ))

    #expect(
      result.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/hero.png"
      ])
  }

  @Test
  func testSanitizerRemovesRemoteImagesWithSignedZeroDimensions() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <img style="max-width: +0px" src="https://tracker.example/wrapped.gif">
        <img src="https://images.example.com/logo.png">
        """
      ))

    #expect(
      result.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/logo.png"
      ])
    #expect(!(result.documentHTML.contains("wrapped.gif")))
  }

  @Test
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
      Issue.record("Expected sanitized HTML")
      return
    }

    #expect(
      presentation.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/hero.png"
      ])
  }

  @Test
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
      Issue.record("Expected sanitized HTML")
      return
    }

    #expect(presentation.remoteImageReferences.isEmpty)
    #expect(!(presentation.documentHTML.contains("tracker.example")))
  }

  @Test
  func testSanitizerDoesNotClassifyUnresolvedCSSVariableDimensionsAsTrackingPixels() throws {
    let body = MailboxMessageBody(
      text: "Newsletter",
      html: """
        <p>Newsletter</p>
        <img src="https://images.example.com/hero.png"
             style="width:1px;width:var(--missing,600px);height:1px;height:var(--missing,100px)">
        """
    )

    guard case .html(let presentation) = MessageHTMLPresentation.resolve(body: body) else {
      Issue.record("Expected sanitized HTML")
      return
    }

    #expect(
      presentation.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/hero.png"
      ])
  }

  @Test
  func testSanitizerPreservesImagesWithUnresolvedMinimumFallbacks() throws {
    let body = MailboxMessageBody(
      text: "Newsletter",
      html: """
        <p>Newsletter</p>
        <img src="https://images.example.com/hero.png"
             style="width:1px;height:1px;min-width:var(--missing,600px);
                    min-height:var(--missing,100px)">
        """
    )

    guard case .html(let presentation) = MessageHTMLPresentation.resolve(body: body) else {
      Issue.record("Expected sanitized HTML")
      return
    }

    #expect(
      presentation.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/hero.png"
      ])
  }

  @Test
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
      Issue.record("Expected sanitized HTML")
      return
    }

    #expect(
      presentation.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/hero.png"
      ])
  }

  @Test
  func testRemoteContentLoaderAdmitsOnlyBoundedHTTPSRasterResponses() async throws {
    let presentation = try remoteContentTestPresentation()
    let png = try requireValue(
      Data(
        base64Encoded:
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
      ))
    let loader = RemoteMessageContentLoader(fetch: { request, maximumByteCount in
      #expect(request.url?.scheme == "https")
      #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
      #expect(request.httpShouldHandleCookies == false)
      #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
      #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
      #expect(request.value(forHTTPHeaderField: "Referer") == nil)
      #expect(maximumByteCount == MailboxMessageImagePolicy.maximumImageByteCount)
      let mimeType =
        request.url?.lastPathComponent == "hero.png"
        ? "image/png"
        : "text/html"
      return (
        request.url?.lastPathComponent == "hero.png" ? png : Data("<script></script>".utf8),
        try requireValue(
          HTTPURLResponse(
            url: try requireValue(request.url),
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": mimeType]
          ))
      )
    })

    let result = try await loader.load(presentation)

    #expect(result.loadedImageCount == 1)
    #expect(result.failedImageCount == 1)
    #expect(
      Set(result.html.remoteImageReferences.map(\.url.absoluteString)) == [
        "https://images.example.com/not-an-image"
      ])
    #expect(result.html.documentHTML.contains("src=\"data:image/png;base64,"))
    #expect(!(result.html.documentHTML.contains("<script")))
    #expect(!(result.html.documentHTML.contains("images.example.com")))
    #expect(!(result.html.documentHTML.contains("legacy.example.com")))
  }

  @Test
  func testRemoteContentLoaderChargesRejectedResponsesAgainstTransferBudget() async throws {
    let (result, requestedMaximumByteCounts) = try await remoteContentTransferBudgetResult(
      referenceCount: 4,
      fetch: { request, maximumByteCount in
        return (
          Data(repeating: 1, count: min(maximumByteCount, 4)),
          try requireValue(
            HTTPURLResponse(
              url: try requireValue(request.url),
              statusCode: 200,
              httpVersion: nil,
              headerFields: ["Content-Type": "text/plain"]
            ))
        )
      }
    )

    #expect(requestedMaximumByteCounts == [10, 6, 2])
    #expect(result.loadedByteCount == 0)
    #expect(result.loadedImageCount == 0)
    #expect(result.failedImageCount == 4)
    #expect(
      result.html.remoteImageReferences.first?.url.absoluteString
        == "https://images.example.com/image-3")
  }

  @Test
  func testRemoteContentLoaderRejectsTruncatedImageAfterReadingDimensions() async throws {
    let presentation = try remoteContentTestPresentation()
    let png = try requireValue(
      Data(
        base64Encoded:
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
      ))
    let loader = RemoteMessageContentLoader(fetch: { request, _ in
      (
        Data(png.prefix(33)),
        try requireValue(
          HTTPURLResponse(
            url: try requireValue(request.url),
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "image/png"]
          ))
      )
    })

    let result = try await loader.load(presentation)

    #expect(result.loadedImageCount == 0)
    #expect(result.failedImageCount == presentation.remoteImageReferences.count)
    #expect(result.html.remoteImageReferences == presentation.remoteImageReferences)
    #expect(!(result.html.documentHTML.contains("src=\"data:image/png;base64,")))
  }

  @Test
  func testRemoteContentLoaderChargesOversizedFailuresAgainstTransferBudget() async throws {
    let (result, requestedMaximumByteCounts) = try await remoteContentTransferBudgetResult(
      referenceCount: 2,
      fetch: { _, maximumByteCount in
        throw RemoteMessageContentError.responseTooLarge(
          receivedByteCount: maximumByteCount
        )
      }
    )

    #expect(requestedMaximumByteCounts == [10])
    #expect(result.loadedByteCount == 0)
    #expect(result.loadedImageCount == 0)
    #expect(result.failedImageCount == 2)
  }

  @Test
  func testRemoteContentLoaderChargesPartialTransferFailuresAgainstTransferBudget() async throws {
    let (result, requestedMaximumByteCounts) = try await remoteContentTransferBudgetResult(
      referenceCount: 4,
      fetch: { _, maximumByteCount in
        throw RemoteMessageContentError.transferFailed(
          receivedByteCount: min(maximumByteCount, 4)
        )
      }
    )

    #expect(requestedMaximumByteCounts == [10, 6, 2])
    #expect(result.loadedByteCount == 0)
    #expect(result.loadedImageCount == 0)
    #expect(result.failedImageCount == 4)
  }

  @Test
  func testRemoteContentDataDelegateReportsBytesReceivedBeforeTransferFailure() async throws {
    PartialFailureURLProtocol.startSignal.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PartialFailureURLProtocol.self]
    let delegate = RemoteMessageContentDataDelegate(maximumByteCount: 10)
    let request = URLRequest(
      url: try requireValue(URL(string: "https://images.example.com/partial.png"))
    )
    let load = Task {
      try await delegate.load(request, configuration: configuration)
    }
    await PartialFailureURLProtocol.startSignal.waitUntilStarted()
    let session = URLSession(configuration: .ephemeral)
    let dataTask = session.dataTask(with: request)
    let response = try requireValue(
      HTTPURLResponse(
        url: try requireValue(request.url),
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "image/png"]
      ))
    delegate.urlSession(session, dataTask: dataTask, didReceive: response) { disposition in
      #expect(disposition == .allow)
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
      Issue.record("Expected the partial transfer to fail")
    } catch RemoteMessageContentError.transferFailed(let receivedByteCount) {
      #expect(receivedByteCount == PartialFailureURLProtocol.data.count)
    } catch {
      Issue.record("Expected a counted transfer failure, got \(error)")
    }
  }

  @Test
  func testRemoteContentDataDelegateReportsOverflowingChunkBytes() async throws {
    PartialFailureURLProtocol.startSignal.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PartialFailureURLProtocol.self]
    let delegate = RemoteMessageContentDataDelegate(maximumByteCount: 5)
    let request = URLRequest(
      url: try requireValue(URL(string: "https://images.example.com/oversized.png"))
    )
    let load = Task {
      try await delegate.load(request, configuration: configuration)
    }
    await PartialFailureURLProtocol.startSignal.waitUntilStarted()
    let session = URLSession(configuration: .ephemeral)
    let dataTask = session.dataTask(with: request)
    let response = try requireValue(
      HTTPURLResponse(
        url: try requireValue(request.url),
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "image/png"]
      ))
    delegate.urlSession(session, dataTask: dataTask, didReceive: response) { disposition in
      #expect(disposition == .allow)
    }
    delegate.urlSession(session, dataTask: dataTask, didReceive: Data(repeating: 0, count: 4))
    delegate.urlSession(session, dataTask: dataTask, didReceive: Data(repeating: 0, count: 3))
    session.invalidateAndCancel()

    do {
      _ = try await load.value
      Issue.record("Expected the transfer to exceed the byte limit")
    } catch RemoteMessageContentError.responseTooLarge(let receivedByteCount) {
      #expect(receivedByteCount == 7)
    } catch {
      Issue.record("Expected a counted response-too-large failure, got \(error)")
    }
  }

  @Test
  func testRemoteContentLoaderPropagatesCancellation() async throws {
    let body = MailboxMessageBody(
      text: "Newsletter",
      html: #"<p>Newsletter</p><img src="https://images.example.com/hero.png">"#
    )
    guard case .html(let presentation) = MessageHTMLPresentation.resolve(body: body) else {
      Issue.record("Expected sanitized HTML")
      return
    }
    let loader = RemoteMessageContentLoader(fetch: { _, _ in
      throw CancellationError()
    })

    do {
      _ = try await loader.load(presentation)
      Issue.record("Cancellation should stop remote content loading")
    } catch is CancellationError {
    } catch {
      Issue.record("Expected cancellation, got \(error)")
    }
  }

  @Test
  func testRemoteContentLoaderAppliesAttemptCapAfterFilteringUnloadableURLs() async throws {
    let invalidReferences = try (0..<MailboxMessageImagePolicy.maximumImageAttemptCount).map {
      RemoteMessageImageReference(
        identifier: "remote-image-\($0)",
        url: try requireValue(URL(string: "http://legacy.example.com/image-\($0).png"))
      )
    }
    let validReference = RemoteMessageImageReference(
      identifier: "remote-image-valid",
      url: try requireValue(URL(string: "https://images.example.com/hero.png"))
    )
    let presentation = SanitizedMessageHTML(
      documentHTML:
        #"<html><body><img data-unwired-remote-image="remote-image-valid"></body></html>"#,
      remoteImageReferences: invalidReferences + [validReference]
    )
    let png = try requireValue(
      Data(
        base64Encoded:
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
      ))
    let loader = RemoteMessageContentLoader(fetch: { request, _ in
      #expect(request.url == validReference.url)
      return (
        png,
        try requireValue(
          HTTPURLResponse(
            url: validReference.url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "image/png"]
          ))
      )
    })

    let result = try await loader.load(presentation)

    #expect(result.loadedImageCount == 1)
    #expect(result.failedImageCount == invalidReferences.count)
    #expect(result.html.documentHTML.contains("src=\"data:image/png;base64,"))
  }

  @Test
  func testRemoteContentLoaderAdvancesRetriesPastFailedAttemptBatch() async throws {
    let references = try (0...MailboxMessageImagePolicy.maximumImageAttemptCount).map {
      RemoteMessageImageReference(
        identifier: "remote-image-\($0)",
        url: try requireValue(URL(string: "https://images.example.com/image-\($0).png"))
      )
    }
    let markers = references.map {
      #"<img data-unwired-remote-image="\#($0.identifier)">"#
    }.joined()
    let presentation = SanitizedMessageHTML(
      documentHTML: "<html><body>\(markers)</body></html>",
      remoteImageReferences: references
    )
    let png = try requireValue(
      Data(
        base64Encoded:
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
      ))
    let validURL = try requireValue(references.last?.url)
    let loader = RemoteMessageContentLoader(fetch: { request, _ in
      guard request.url == validURL else { throw URLError(.badServerResponse) }
      return (
        png,
        try requireValue(
          HTTPURLResponse(
            url: validURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "image/png"]
          ))
      )
    })

    let firstResult = try await loader.load(presentation)
    let retryResult = try await loader.load(firstResult.html)

    #expect(firstResult.loadedImageCount == 0)
    #expect(firstResult.html.remoteImageReferences.first?.url == validURL)
    #expect(retryResult.loadedImageCount == 1)
  }

  @Test
  func testRemoteContentLoaderStopsAtAggregateDeadline() async throws {
    var currentTime: TimeInterval = 0
    let references = try (0..<2).map {
      RemoteMessageImageReference(
        identifier: "remote-image-\($0)",
        url: try requireValue(URL(string: "https://images.example.com/image-\($0).png"))
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
        requestedURLs.append(try requireValue(request.url))
        #expect(request.timeoutInterval == 30)
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

    #expect(requestedURLs == [references[0].url])
    #expect(result.failedImageCount == 2)
  }

  @Test
  func testRemoteContentLoaderChargesRepeatedMarkerExpansionsAgainstByteBudget() async throws {
    let reference = RemoteMessageImageReference(
      identifier: "remote-image-0",
      url: try requireValue(URL(string: "https://images.example.com/hero.png"))
    )
    let repeatedMarkers = String(
      repeating: #"<img data-unwired-remote-image="remote-image-0">"#,
      count: 5
    )
    let presentation = SanitizedMessageHTML(
      documentHTML: "<html><body>\(repeatedMarkers)</body></html>",
      remoteImageReferences: [reference]
    )
    let png = try requireValue(
      Data(
        base64Encoded:
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
      ))
    let loader = RemoteMessageContentLoader(fetch: { _, maximumByteCount in
      #expect(maximumByteCount == MailboxMessageImagePolicy.maximumTotalByteCount / 5)
      return (
        png,
        try requireValue(
          HTTPURLResponse(
            url: reference.url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "image/png"]
          ))
      )
    })

    let result = try await loader.load(presentation)

    #expect(result.loadedImageCount == 1)
    #expect(
      result.html.documentHTML.components(separatedBy: "src=\"data:image/png;base64,").count - 1
        == 5)
  }

  @Test
  func testRemoteContentLoaderSkipsOverBudgetReferenceAndLoadsLaterImage() async throws {
    let references = try (0..<2).map {
      RemoteMessageImageReference(
        identifier: "remote-image-\($0)",
        url: try requireValue(URL(string: "https://images.example.com/image-\($0).png"))
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
    let png = try requireValue(
      Data(
        base64Encoded:
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
      ))
    var requestedURLs: [URL] = []
    let loader = RemoteMessageContentLoader(
      maximumTotalPixelCount: 1,
      fetch: { request, _ in
        let url = try requireValue(request.url)
        requestedURLs.append(url)
        return (
          png,
          try requireValue(
            HTTPURLResponse(
              url: url,
              statusCode: 200,
              httpVersion: nil,
              headerFields: ["Content-Type": "image/png"]
            ))
        )
      }
    )

    let result = try await loader.load(presentation)

    #expect(requestedURLs == [references[1].url])
    #expect(result.loadedImageCount == 1)
    #expect(result.html.remoteImageReferences == [references[0]])
  }

  @Test
  func testRemoteContentSessionUsesEphemeralCookieFreeStorage() {
    let configuration = RemoteMessageContentSession.makeConfiguration()

    #expect(!(configuration.httpShouldSetCookies))
    #expect(configuration.httpCookieStorage == nil)
    #expect(configuration.urlCredentialStorage == nil)
    #expect(configuration.urlCache == nil)
    #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    #expect(configuration.timeoutIntervalForResource == 30)
  }

  @Test
  func testRemoteContentLoaderRejectsNonPublicLiteralDestinationsBeforeFetch() async throws {
    let references = try [
      "https://127.0.0.1/image.png",
      "https://10.0.0.1/image.png",
      "https://[::1]/image.png",
    ].enumerated().map { index, value in
      RemoteMessageImageReference(
        identifier: "remote-image-\(index)",
        url: try requireValue(URL(string: value))
      )
    }
    let markers = references.map {
      #"<img data-unwired-remote-image="\#($0.identifier)">"#
    }.joined()
    var requestedURLs: [URL] = []
    let loader = RemoteMessageContentLoader(fetch: { request, _ in
      requestedURLs.append(try requireValue(request.url))
      throw URLError(.cannotConnectToHost)
    })

    let result = try await loader.load(
      SanitizedMessageHTML(
        documentHTML: "<html><body>\(markers)</body></html>",
        remoteImageReferences: references
      )
    )

    #expect(requestedURLs.isEmpty)
    #expect(result.failedImageCount == references.count)
  }

  @Test
  func testRemoteContentAddressPolicyRejectsNonPublicSpecialUseRanges() throws {
    let nonPublicAddresses = [
      "0.0.0.0", "10.0.0.1", "100.64.0.1", "127.0.0.1", "169.254.1.1",
      "172.16.0.1", "192.0.0.1", "192.0.2.1", "192.168.0.1", "198.18.0.1",
      "198.51.100.1", "203.0.113.1", "224.0.0.1", "240.0.0.1", "255.255.255.255",
      "::", "::1", "::ffff:127.0.0.1", "64:ff9b::1", "100::1", "2001::1",
      "2001:db8::1", "2002::1", "3ffe::1", "3fff::1", "fc00::1", "fe80::1", "ff00::1",
    ]
    for value in nonPublicAddresses {
      let address = try requireValue(
        RemoteMessageContentIPAddress.numericAddress(value),
        "Expected \(value) to parse as an IP address")
      #expect(!(address.isPublic), "Unexpected public address: \(value)")
    }

    for value in [
      "8.8.8.8", "93.184.216.34", "192.0.0.9", "2001:3::1", "2606:4700:4700::1111",
    ] {
      let address = try requireValue(RemoteMessageContentIPAddress.numericAddress(value))
      #expect(address.isPublic, "Unexpected blocked public address: \(value)")
    }
  }

  @Test
  func testRemoteContentNetworkClientRejectsMixedDNSAnswersBeforeTransport() async throws {
    let publicAddress = try requireValue(
      RemoteMessageContentIPAddress.numericAddress("93.184.216.34"))
    let privateAddress = try requireValue(
      RemoteMessageContentIPAddress.numericAddress("192.168.1.10"))
    let client = RemoteMessageContentNetworkClient(
      resolver: { _ in [publicAddress, privateAddress] },
      transfer: { _, _, _, _ in
        Issue.record("Mixed DNS answers must be rejected before connecting")
        throw URLError(.cannotConnectToHost)
      }
    )

    do {
      _ = try await client.data(
        for: URLRequest(
          url: try requireValue(URL(string: "https://images.example.com/hero.png"))
        ),
        maximumByteCount: 1_024
      )
      Issue.record("Expected mixed DNS answers to be blocked")
    } catch {
      #expect(error as? RemoteMessageContentNetworkError == .blockedDestination)
    }
  }

  @Test
  func testRemoteContentNetworkClientPinsAddressAndLoadsValidPublicHTTPSResponse() async throws {
    let publicAddress = try requireValue(
      RemoteMessageContentIPAddress.numericAddress("93.184.216.34"))
    let privateAddress = try requireValue(RemoteMessageContentIPAddress.numericAddress("127.0.0.1"))
    var resolutionCount = 0
    var connectedAddresses: [RemoteMessageContentIPAddress] = []
    let client = RemoteMessageContentNetworkClient(
      resolver: { _ in
        resolutionCount += 1
        return resolutionCount == 1 ? [publicAddress] : [privateAddress]
      },
      transfer: { _, address, tlsServerName, _ in
        connectedAddresses.append(address)
        #expect(tlsServerName == "images.example.com")
        return RemoteMessageContentPinnedHTTPResponse(
          body: Data([0x89, 0x50, 0x4E, 0x47]),
          headerFields: ["Content-Type": "image/png"],
          statusCode: 200
        )
      }
    )

    let load = try await client.data(
      for: URLRequest(
        url: try requireValue(URL(string: "https://images.example.com/hero.png"))
      ),
      maximumByteCount: 1_024
    )

    #expect(resolutionCount == 1)
    #expect(connectedAddresses == [publicAddress])
    #expect(load.data == Data([0x89, 0x50, 0x4E, 0x47]))
    #expect(load.receivedByteCount == load.data.count)
    #expect((load.response as? HTTPURLResponse)?.statusCode == 200)
  }

  @Test
  func testRemoteContentNetworkClientChargesRedirectBodiesAndCarriesDeadline() async throws {
    let publicAddress = try requireValue(
      RemoteMessageContentIPAddress.numericAddress("93.184.216.34"))
    var maximumByteCounts: [Int] = []
    var timeoutIntervals: [TimeInterval] = []
    var transferCount = 0
    var monotonicTimes: [TimeInterval] = [100, 101, 102, 110, 120]
    let finalMonotonicTime = monotonicTimes.last ?? 0
    var monotonicTimeOverrunCount = 0
    let client = RemoteMessageContentNetworkClient(
      resolver: { _ in [publicAddress] },
      transfer: { request, _, _, maximumByteCount in
        maximumByteCounts.append(maximumByteCount)
        timeoutIntervals.append(request.timeoutInterval)
        transferCount += 1
        if transferCount == 1 {
          return RemoteMessageContentPinnedHTTPResponse(
            body: Data(repeating: 0, count: 4),
            headerFields: ["Location": "https://cdn.example.com/final.png"],
            statusCode: 302
          )
        }
        return RemoteMessageContentPinnedHTTPResponse(
          body: Data(repeating: 1, count: 3),
          headerFields: ["Content-Type": "image/png"],
          statusCode: 200
        )
      },
      monotonicTime: {
        guard !monotonicTimes.isEmpty else {
          monotonicTimeOverrunCount += 1
          return finalMonotonicTime
        }
        return monotonicTimes.removeFirst()
      }
    )

    var request = URLRequest(
      url: try requireValue(URL(string: "https://images.example.com/start.png"))
    )
    request.timeoutInterval = 30
    let load = try await client.data(
      for: request,
      maximumByteCount: 10
    )

    #expect(maximumByteCounts == [10, 6])
    #expect(timeoutIntervals == [28, 10])
    #expect(load.data.count == 3)
    #expect(load.receivedByteCount == 7)
    #expect(monotonicTimeOverrunCount == 0)
  }

  @Test
  func testRemoteContentPinnedHTTPSClientRejectsOutOfRangePort() async throws {
    let publicAddress = try requireValue(
      RemoteMessageContentIPAddress.numericAddress("93.184.216.34"))
    do {
      _ = try await RemoteMessageContentPinnedHTTPSClient.transfer(
        URLRequest(
          url: try requireValue(URL(string: "https://images.example.com:65536/image.png"))
        ),
        address: publicAddress,
        tlsServerName: "images.example.com",
        maximumByteCount: 1_024
      )
      Issue.record("Expected an out-of-range port to be rejected")
    } catch {
      #expect(error as? RemoteMessageContentNetworkError == .invalidResponse)
    }
  }

  @Test
  func testRemoteContentChunkedDecoderReportsOverflowWithoutTrapping() throws {
    let response = Data(
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
        .appending("1\r\na\r\n7fffffffffffffff\r\n")
        .utf8
    )

    #expect {
      try RemoteMessageContentConnectionController.parseResponse(
        response,
        maximumBodyByteCount: 10
      )
    } throws: { error in
      guard case RemoteMessageContentError.responseTooLarge(let receivedByteCount) = error else {
        Issue.record("Expected a counted response-too-large failure, got \(error)")
        return true
      }
      #expect(receivedByteCount == Int.max)
      return true
    }
  }

  @Test
  func testRemoteContentNetworkClientStopsAfterThreeRedirects() async throws {
    let publicAddress = try requireValue(
      RemoteMessageContentIPAddress.numericAddress("93.184.216.34"))
    var transferCount = 0
    let client = RemoteMessageContentNetworkClient(
      resolver: { _ in [publicAddress] },
      transfer: { _, _, _, _ in
        transferCount += 1
        return RemoteMessageContentPinnedHTTPResponse(
          body: Data(),
          headerFields: ["Location": "https://cdn.example.com/next.png"],
          statusCode: 302
        )
      }
    )

    do {
      _ = try await client.data(
        for: URLRequest(
          url: try requireValue(URL(string: "https://images.example.com/start.png"))
        ),
        maximumByteCount: 1_024
      )
      Issue.record("Expected the redirect limit to fail closed")
    } catch {
      #expect(error as? RemoteMessageContentNetworkError == .tooManyRedirects)
    }
    #expect(transferCount == 4)
  }

  @Test
  func testRemoteContentPinnedRequestRequiresIdentityContentCoding() throws {
    var request = URLRequest(
      url: try requireValue(URL(string: "https://images.example.com/image.png"))
    )
    request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")

    let serializedRequest = try RemoteMessageContentPinnedHTTPSClient.serializedRequest(
      request,
      tlsServerName: "images.example.com"
    )
    let requestText = try requireValue(String(data: serializedRequest, encoding: .utf8))

    #expect(requestText.contains("\r\nAccept-Encoding: identity\r\n"))
    #expect(!(requestText.contains("Accept-Encoding: gzip")))
  }

  @Test
  func testRemoteContentResponseParserDecodesValidChunkedBody() throws {
    let response = Data(
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
        .appending("4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n")
        .utf8
    )

    let parsed = try RemoteMessageContentConnectionController.parseResponse(
      response,
      maximumBodyByteCount: 10
    )

    #expect(parsed.body == Data("Wikipedia".utf8))
  }

  @Test
  func testRemoteContentResponseParserReportsOversizedAndTruncatedBodies() throws {
    let oversized = Data("HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\n12345678901".utf8)
    #expect {
      try RemoteMessageContentConnectionController.parseResponse(
        oversized,
        maximumBodyByteCount: 10
      )
    } throws: { error in
      guard case RemoteMessageContentError.responseTooLarge(let receivedByteCount) = error else {
        Issue.record("Expected a counted response-too-large failure, got \(error)")
        return true
      }
      #expect(receivedByteCount == 11)
      return true
    }

    let truncated = Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n123".utf8)
    #expect {
      try RemoteMessageContentConnectionController.parseResponse(
        truncated,
        maximumBodyByteCount: 10
      )
    } throws: { error in
      guard case RemoteMessageContentError.transferFailed(let receivedByteCount) = error else {
        Issue.record("Expected a counted transfer failure, got \(error)")
        return true
      }
      #expect(receivedByteCount == 3)
      return true
    }
  }

  @Test
  func testRemoteContentResponseParserRejectsMalformedStatusLine() throws {
    let response = Data("HTTP/2 200 OK\r\nContent-Length: 0\r\n\r\n".utf8)

    #expect {
      try RemoteMessageContentConnectionController.parseResponse(
        response,
        maximumBodyByteCount: 10
      )
    } throws: { error in
      #expect(error as? RemoteMessageContentNetworkError == .invalidResponse)
      return true
    }
  }

  @Test
  func testRemoteContentNetworkClientValidatesEveryRedirectDestination() async throws {
    let publicAddress = try requireValue(
      RemoteMessageContentIPAddress.numericAddress("93.184.216.34"))
    let privateAddress = try requireValue(RemoteMessageContentIPAddress.numericAddress("10.0.0.8"))
    var resolvedHosts: [String] = []
    var transportedHosts: [String] = []
    let client = RemoteMessageContentNetworkClient(
      resolver: { host in
        resolvedHosts.append(host)
        return host == "cdn.example.com" ? [publicAddress] : [privateAddress]
      },
      transfer: { _, _, tlsServerName, _ in
        transportedHosts.append(tlsServerName)
        return RemoteMessageContentPinnedHTTPResponse(
          body: Data(),
          headerFields: ["Location": "https://internal.example.com/image.png"],
          statusCode: 302
        )
      }
    )

    do {
      _ = try await client.data(
        for: URLRequest(
          url: try requireValue(URL(string: "https://cdn.example.com/image.png"))
        ),
        maximumByteCount: 1_024
      )
      Issue.record("Expected the private redirect destination to be blocked")
    } catch {
      #expect(error as? RemoteMessageContentNetworkError == .blockedDestination)
    }
    #expect(resolvedHosts == ["cdn.example.com", "internal.example.com"])
    #expect(transportedHosts == ["cdn.example.com"])
  }

  @Test
  func testRemoteContentRedirectsRemainHTTPSAndDropRequestIdentity() throws {
    var secureRequest = URLRequest(
      url: try requireValue(URL(string: "https://cdn.example.com/image.png"))
    )
    secureRequest.httpShouldHandleCookies = true
    secureRequest.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
    secureRequest.setValue("session=secret", forHTTPHeaderField: "Cookie")
    secureRequest.setValue("https://mail.example.com/message", forHTTPHeaderField: "Referer")

    let redirectedRequest = try requireValue(
      RemoteMessageContentRedirectPolicy.redirectedRequest(secureRequest))

    #expect(!(redirectedRequest.httpShouldHandleCookies))
    #expect(redirectedRequest.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(redirectedRequest.value(forHTTPHeaderField: "Cookie") == nil)
    #expect(redirectedRequest.value(forHTTPHeaderField: "Referer") == nil)
    #expect(
      RemoteMessageContentRedirectPolicy.redirectedRequest(
        URLRequest(url: try requireValue(URL(string: "http://cdn.example.com/image.png")))
      ) == nil)
    #expect(
      RemoteMessageContentRedirectPolicy.redirectedRequest(
        URLRequest(url: try requireValue(URL(string: "https://127.0.0.1/image.png")))
      ) == nil)
  }

  @Test
  func testRemoteContentRedirectsStopAfterThreeHops() throws {
    let delegate = RemoteMessageContentRedirectDelegate()
    let session = URLSession(configuration: .ephemeral)
    let task = session.dataTask(
      with: try requireValue(URL(string: "https://images.example.com/start.png"))
    )
    let response = try requireValue(
      HTTPURLResponse(
        url: try requireValue(URL(string: "https://images.example.com/start.png")),
        statusCode: 302,
        httpVersion: nil,
        headerFields: nil
      ))

    for hop in 1...4 {
      var redirectedRequest: URLRequest?
      delegate.urlSession(
        session,
        task: task,
        willPerformHTTPRedirection: response,
        newRequest: URLRequest(
          url: try requireValue(URL(string: "https://images.example.com/hop-\(hop).png"))
        )
      ) { request in
        redirectedRequest = request
      }
      if hop <= 3 {
        #expect(redirectedRequest != nil)
      } else {
        #expect(redirectedRequest == nil)
      }
    }

    session.invalidateAndCancel()
  }

  @MainActor
  @Test
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

    #expect(receivedHTML.isEmpty)
    #expect(presentation.state == .blocked)

    presentation.requestLoad()
    #expect(presentation.displayedHTML(originalHTML: originalHTML) == originalHTML)
    await presentation.load(originalHTML: originalHTML, using: loader)
    presentation.requestLoad()
    #expect(presentation.displayedHTML(originalHTML: originalHTML) == partiallyLoadedHTML)
    await presentation.load(originalHTML: originalHTML, using: loader)

    #expect(receivedHTML == [originalHTML, partiallyLoadedHTML])
    #expect(presentation.displayedHTML(originalHTML: originalHTML) == partiallyLoadedHTML)
    #expect(presentation.state == .failed(partiallyLoadedHTML.remoteImageReferences.count))

    presentation.reset()

    #expect(presentation.loadRequest == nil)
    #expect(presentation.state == .blocked)
    #expect(presentation.displayedHTML(originalHTML: originalHTML) == originalHTML)
  }

  @MainActor
  @Test
  func testRemoteContentPresentationAppliesAlwaysAndNeverPolicies() async throws {
    let originalHTML = try remoteContentTestPresentation()
    let presentation = RemoteMessageContentPresentation()
    var receivedHTML: [SanitizedMessageHTML] = []
    let loader: (SanitizedMessageHTML) async throws -> RemoteMessageContentLoadResult = { html in
      receivedHTML.append(html)
      return RemoteMessageContentLoadResult(
        failedImageCount: 0,
        html: SanitizedMessageHTML(
          documentHTML: html.documentHTML,
          remoteImageReferences: []
        ),
        loadedImageCount: html.remoteImageReferences.count
      )
    }

    presentation.apply(policy: .alwaysLoad, hasRemoteImages: true)
    #expect(presentation.state == .loading)
    await presentation.load(originalHTML: originalHTML, using: loader)
    #expect(receivedHTML == [originalHTML])
    #expect(presentation.displayedHTML(originalHTML: originalHTML).remoteImageReferences.isEmpty)

    presentation.apply(policy: .alwaysLoad, hasRemoteImages: false)
    #expect(presentation.state == .blocked)
    #expect(presentation.loadRequest == nil)

    presentation.apply(policy: .never, hasRemoteImages: true)
    #expect(presentation.state == .blocked)
    #expect(presentation.loadRequest == nil)
    #expect(presentation.displayedHTML(originalHTML: originalHTML) == originalHTML)

    presentation.apply(policy: .ask, hasRemoteImages: true)
    #expect(presentation.state == .blocked)
    #expect(presentation.loadRequest == nil)
  }

  @MainActor
  @Test
  func testResolvedCIDImageRendersInsideSecuredWebView() async throws {
    let imageData = try requireValue(
      Data(
        base64Encoded:
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
      ))
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
      Issue.record("Expected sanitized HTML")
      return
    }
    let configuration = MessageHTMLWebViewConfiguration.make()
    let webView = WKWebView(frame: .zero, configuration: configuration)
    MessageHTMLWebViewConfiguration.applyPrivacySettings(to: webView)
    let navigationFinished = expectation(description: "Inline image document loaded")
    let navigationDelegate = MessageHTMLTestNavigationDelegate(expectation: navigationFinished)
    webView.navigationDelegate = navigationDelegate

    webView.loadHTMLString(presentation.documentHTML, baseURL: nil)
    await fulfillment(of: [navigationFinished], timeout: 15)

    #expect(navigationDelegate.error == nil)
    let didRender =
      try await webView.evaluateJavaScript(
        "document.images.length === 1 && document.images[0].complete "
          + "&& document.images[0].naturalWidth === 1"
      ) as? Bool
    #expect(didRender == true)
  }

  @Test
  func testSanitizedDocumentNormalizesEmailColorsOntoANeutralLightCanvas() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p style="color: #fff; background-color: #000;
          background-image: url(https://example.com/background.png)">Hello</p>
        """
      ))

    #expect(!(result.documentHTML.contains("style=\"color:")))
    #expect(!(result.documentHTML.contains("background-image")))
    #expect(result.documentHTML.contains(":root { color-scheme: light; }"))
    #expect(result.documentHTML.contains("background: #fff;"))
    #expect(result.documentHTML.contains("color: #111;"))
  }

  @Test
  func testPresentationUsesHTMLAndFallsBackForMissingSanitizationOrRenderingFailure() {
    let body = MailboxMessageBody(text: "Readable fallback", html: "<p>Rich message</p>")
    let sanitized = SanitizedMessageHTML(documentHTML: "document")
    var receivedDefaultQuotedReplyFlag = true
    var receivedQuotedReplyFlag = false

    #expect(
      MessageHTMLPresentation.resolve(body: body) { _, removesQuotedReplies in
        receivedDefaultQuotedReplyFlag = removesQuotedReplies
        return sanitized
      } == .html(sanitized))
    #expect(!receivedDefaultQuotedReplyFlag)
    #expect(
      MessageHTMLPresentation.resolve(body: body) { _, _ in nil }
        == .plainText("Readable fallback"))
    #expect(
      MessageHTMLPresentation.resolve(body: body) { _, _ in throw TestError.sanitizationFailed }
        == .plainText("Readable fallback"))
    #expect(
      MessageHTMLPresentation.resolve(
        body: body,
        renderingFailed: true,
        sanitizer: { _, _ in sanitized }
      ) == .plainText("Readable fallback"))
    #expect(
      MessageHTMLPresentation.resolve(body: MailboxMessageBody(text: "Plain only"))
        == .plainText("Plain only"))
    #expect(
      MessageHTMLPresentation.resolve(
        body: body,
        removesQuotedReplies: true,
        sanitizer: { _, removesQuotedReplies in
          receivedQuotedReplyFlag = removesQuotedReplies
          return sanitized
        }
      ) == .html(sanitized))
    #expect(receivedQuotedReplyFlag)
  }

  @MainActor
  @Test
  func testPresentationPreparationSanitizesOffTheMainThread() async throws {
    let body = MailboxMessageBody(text: "Readable fallback", html: "<p>Rich message</p>")

    let presentation = try await MessageHTMLPresentation.prepare(body: body) { _, _ in
      SanitizedMessageHTML(
        documentHTML: Thread.isMainThread ? "main" : "background"
      )
    }

    #expect(
      presentation
        == .html(
          SanitizedMessageHTML(
            documentHTML: "background"
          )
        ))
  }

  @Test
  func testLinkPolicyOpensAllowedSchemesOnlyForUserActivation() throws {
    let webURL = try requireValue(URL(string: "https://example.com/path"))
    let mailURL = try requireValue(URL(string: "mailto:person@example.com"))
    let phoneURL = try requireValue(URL(string: "tel:+420123456789"))
    let unsafeURL = try requireValue(URL(string: "javascript:alert('x')"))

    #expect(MessageHTMLLinkPolicy.externalURL(webURL, isUserActivated: true) == webURL)
    #expect(MessageHTMLLinkPolicy.externalURL(mailURL, isUserActivated: true) == mailURL)
    #expect(MessageHTMLLinkPolicy.externalURL(phoneURL, isUserActivated: true) == phoneURL)
    #expect(MessageHTMLLinkPolicy.externalURL(webURL, isUserActivated: false) == nil)
    #expect(MessageHTMLLinkPolicy.externalURL(unsafeURL, isUserActivated: true) == nil)
  }

  @Test
  func testSanitizationRetainsVisibleRichLinkTextForOnDeviceInspection() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <a href="https://accounts.example.test/session">https://accounts.example.test</a>
        <a href="https://destination.example.test/path"><strong>Review account</strong></a>
        """
      ))

    #expect(
      result.linkPresentations == [
        MessageHTMLLinkPresentation(
          destination: try requireValue(
            URL(string: "https://accounts.example.test/session")
          ),
          displayedText: "https://accounts.example.test"
        ),
        MessageHTMLLinkPresentation(
          destination: try requireValue(
            URL(string: "https://destination.example.test/path")
          ),
          displayedText: "Review account"
        ),
      ])
  }

  @Test
  func testSanitizationIncludesImageAltTextInLinkPresentation() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <a href="https://destination.example.test/account">
          <img src="https://images.example.test/hero.png" alt="https://bank.example.test">
        </a>
        """
      ))

    #expect(result.linkPresentations.first?.displayedText == "https://bank.example.test")
  }

  @Test
  func testOrdinaryAndDescriptiveLinksDoNotProduceSafetyClaimsOrWarnings() throws {
    let destination = try requireValue(URL(string: "https://example.test/account"))

    #expect(
      SuspiciousLinkDetector.warning(
        for: destination,
        presentations: [
          MessageHTMLLinkPresentation(
            destination: destination,
            displayedText: "Review account"
          )
        ]
      ) == nil
    )
    #expect(
      SuspiciousLinkDetector.warning(
        for: destination,
        presentations: [
          MessageHTMLLinkPresentation(
            destination: destination,
            displayedText: "www.example.test/account"
          )
        ]
      ) == nil
    )
    #expect(
      SuspiciousLinkDetector.warning(
        for: try requireValue(
          URL(string: "https://example.test/login?next=%2Faccount")
        )) == nil
    )
  }

  @Test
  func testDisplayedWebsitePathAndSchemeDeceptionAreExplained() throws {
    let destination = try requireValue(URL(string: "http://login.example.test/private"))
    let warning = try requireValue(
      SuspiciousLinkDetector.warning(
        for: destination,
        presentations: [
          MessageHTMLLinkPresentation(
            destination: destination,
            displayedText: "https://bank.example.test/account"
          )
        ]
      ))

    #expect(warning.destination == destination)
    #expect(warning.reasons.contains(.displayedSchemeMismatch))
    #expect(warning.reasons.contains(.displayedDestinationMismatch))
    #expect(warning.explanation.contains(destination.absoluteString))
  }

  @Test
  func testDisplayedWebsitePortMismatchIsExplained() throws {
    let destination = try requireValue(URL(string: "https://example.test:8443/account"))
    let warning = try requireValue(
      SuspiciousLinkDetector.warning(
        for: destination,
        presentations: [
          MessageHTMLLinkPresentation(
            destination: destination,
            displayedText: "https://example.test:443/account"
          )
        ]
      ))

    #expect(warning.reasons.contains(.displayedDestinationMismatch))
  }

  @Test
  func testRootPathPresentationMatchesCanonicalNavigationURL() throws {
    let navigationURL = try requireValue(URL(string: "https://evil.example.test/"))
    let warning = try requireValue(
      SuspiciousLinkDetector.warning(
        for: navigationURL,
        presentations: [
          MessageHTMLLinkPresentation(
            destination: try requireValue(URL(string: "https://evil.example.test")),
            displayedText: "https://bank.example.test"
          )
        ]
      ))

    #expect(warning.reasons.contains(.displayedDestinationMismatch))
  }

  @Test
  func testDisplayedWebsiteTokenInProseIsInspected() throws {
    let destination = try requireValue(URL(string: "https://evil.example.test/login"))
    let warning = try requireValue(
      SuspiciousLinkDetector.warning(
        for: destination,
        presentations: [
          MessageHTMLLinkPresentation(
            destination: destination,
            displayedText: "Continue at https://bank.example.test/login now"
          )
        ]
      ))

    #expect(warning.reasons.contains(.displayedDestinationMismatch))
  }

  @Test
  func testDisplayedBareDomainTokenInProseIsInspected() throws {
    let destination = try requireValue(URL(string: "https://evil.example.test/account"))
    let warning = try requireValue(
      SuspiciousLinkDetector.warning(
        for: destination,
        presentations: [
          MessageHTMLLinkPresentation(
            destination: destination,
            displayedText: "Visit bank.example.test/account now"
          )
        ]
      ))

    #expect(warning.reasons.contains(.displayedDestinationMismatch))
  }

  @Test
  func testDisplayedEmailAddressInProseIsNotTreatedAsWebsite() throws {
    let destination = try requireValue(URL(string: "https://evil.example.test/account"))
    let warning = SuspiciousLinkDetector.warning(
      for: destination,
      presentations: [
        MessageHTMLLinkPresentation(
          destination: destination,
          displayedText: "Email person@bank.example.test for help"
        )
      ]
    )

    #expect(warning?.reasons == nil)
  }

  @Test
  func testDisplayedWebsiteFragmentMismatchIsExplained() throws {
    let destination = try requireValue(URL(string: "https://example.test/account#security"))
    let warning = try requireValue(
      SuspiciousLinkDetector.warning(
        for: destination,
        presentations: [
          MessageHTMLLinkPresentation(
            destination: destination,
            displayedText: "https://example.test/account#billing"
          )
        ]
      ))

    #expect(warning.reasons.contains(.displayedDestinationMismatch))
  }

  @Test
  func testProtocolRelativeDisplayedWebsiteIsInspected() throws {
    let destination = try requireValue(URL(string: "https://evil.example.test/login"))
    let warning = try requireValue(
      SuspiciousLinkDetector.warning(
        for: destination,
        presentations: [
          MessageHTMLLinkPresentation(
            destination: destination,
            displayedText: "//bank.example.test/login"
          )
        ]
      ))

    #expect(warning.reasons.contains(.displayedDestinationMismatch))
  }

  @Test
  func testNonHierarchicalLabelsAndDisplayedCredentialsAreExplained() throws {
    let destination = try requireValue(URL(string: "https://evil.example.test/login"))
    for displayedText in [
      "mailto:support@bank.example.test",
      "tel:+15551234",
      "https://bank.example.test@evil.example.test/login",
    ] {
      let warning = try requireValue(
        SuspiciousLinkDetector.warning(
          for: destination,
          presentations: [
            MessageHTMLLinkPresentation(
              destination: destination,
              displayedText: displayedText
            )
          ]
        ))
      #expect(!warning.reasons.isEmpty)
    }

    let credentialsWarning = try requireValue(
      SuspiciousLinkDetector.warning(
        for: destination,
        presentations: [
          MessageHTMLLinkPresentation(
            destination: destination,
            displayedText: "https://bank.example.test@evil.example.test/login"
          )
        ]
      ))
    #expect(credentialsWarning.reasons.contains(.embeddedCredentials))
  }

  @Test
  func testHostAndUnicodeDeceptionSignalsAreDetectedWithoutNetworkAccess() throws {
    let numeric = try requireValue(URL(string: "https://192.0.2.8/sign-in"))
    let internationalized = try requireValue(
      URL(string: "https://xn--pple-43d.example/sign-in")
    )
    let credentials = try requireValue(
      URL(string: "https://trusted.example@destination.example/sign-in")
    )
    let directionalControl = try requireValue(
      URL(string: "https://example.test/%E2%80%AEtxt.exe")
    )

    #expect(
      SuspiciousLinkDetector.warning(for: numeric)?.reasons.contains(.numericHost) == true)
    #expect(
      SuspiciousLinkDetector.warning(for: internationalized)?.reasons.contains(
        .internationalizedHost
      ) == true)
    #expect(
      SuspiciousLinkDetector.warning(for: credentials)?.reasons.contains(
        .embeddedCredentials
      ) == true)
    #expect(
      SuspiciousLinkDetector.warning(for: directionalControl)?.reasons.contains(
        .deceptiveCharacters
      ) == true)
  }

  @Test
  func testCrossSiteRedirectParameterWarnsBeforeExactSystemHandoff() throws {
    let destination = try requireValue(
      URL(
        string:
          "https://links.example.test/open?redirect_url="
          + "https%3A%2F%2Fdestination.example.test%2Faccount%3Ftoken%3Dopaque#source"
      ))
    let warning = try requireValue(SuspiciousLinkDetector.warning(for: destination))

    #expect(warning.destination.absoluteString == destination.absoluteString)
    #expect(warning.reasons == [.crossSiteRedirect])

    let protocolRelative = try requireValue(
      URL(
        string:
          "https://links.example.test/open?redirect_url="
          + "%2F%2Fdestination.example.test%2Faccount"
      ))
    #expect(
      SuspiciousLinkDetector.warning(for: protocolRelative)?.reasons == [.crossSiteRedirect]
    )
  }

  @Test
  func testPlainTextURLsBecomeLinksForTheSameOpenPolicy() throws {
    let destination = try requireValue(URL(string: "https://example.test/plain"))
    let disallowedDestination = try requireValue(URL(string: "ftp://example.test/file"))
    let attributed = MessagePlainTextLinks.attributed(
      "Read \(destination.absoluteString), not \(disallowedDestination.absoluteString)."
    )

    #expect(attributed.runs.contains { $0.link == destination })
    #expect(!(attributed.runs.contains { $0.link == disallowedDestination }))
  }

  @Test
  func testLegacySanitizedPresentationDefaultsToNoRecordedLinks() {
    #expect(SanitizedMessageHTML(documentHTML: "legacy").linkPresentations.isEmpty)
  }

  @MainActor
  @Test
  func testWebViewConfigurationDisablesPageJavaScriptAndPersistentStorage() {
    let configuration = MessageHTMLWebViewConfiguration.make()
    let webView = WKWebView(frame: .zero, configuration: configuration)
    MessageHTMLWebViewConfiguration.applyPrivacySettings(to: webView)

    #expect(!(configuration.defaultWebpagePreferences.allowsContentJavaScript))
    #expect(!(configuration.websiteDataStore.isPersistent))
    #expect(!(webView.allowsLinkPreview))
  }

  @MainActor
  @Test
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

    #expect(height == nil, "Initial observation must not mutate SwiftUI state synchronously")
    await fulfillment(of: [heightChanged], timeout: 1)
    #expect(height == 1)
    coordinator.stopObservingContentSize()
  }

  @Test
  func testLayoutUsesContentSizeAndViewportWithAVisibleMinimum() {
    let viewportSize = CGSize(width: 500, height: 800)

    #expect(MessageHTMLLayout.height(for: .zero) == 1)
    #expect(!(MessageHTMLLayout.isInternallyScrollable(for: .zero, within: viewportSize)))
    #expect(MessageHTMLLayout.height(for: CGSize(width: 500, height: 128.5)) == 128.5)
    #expect(
      !(MessageHTMLLayout.isInternallyScrollable(
        for: CGSize(width: 500, height: MessageHTMLLayout.maximumHeight),
        within: viewportSize
      )))
    #expect(
      MessageHTMLLayout.isInternallyScrollable(
        for: CGSize(width: 501, height: 128.5),
        within: viewportSize
      ))
    #expect(
      !(MessageHTMLLayout.isInternallyScrollable(
        for: CGSize(width: 501, height: 128.5),
        within: CGSize(width: 502, height: 800)
      )))
    #expect(
      MessageHTMLLayout.height(for: CGSize(width: 500, height: 100_000_000))
        == MessageHTMLLayout.maximumHeight)
    #expect(
      MessageHTMLLayout.isInternallyScrollable(
        for: CGSize(width: 500, height: 100_000_000),
        within: viewportSize
      ))
  }

  @Test
  func testNavigationFailureIgnoresIntentionalCancellation() {
    let urlCancellation = NSError(domain: NSURLErrorDomain, code: URLError.cancelled.rawValue)
    let policyCancellation = NSError(domain: "WebKitErrorDomain", code: 102)
    let failure = NSError(domain: NSURLErrorDomain, code: URLError.cannotConnectToHost.rawValue)

    #expect(!(MessageHTMLNavigationFailure.shouldTriggerFallback(for: urlCancellation)))
    #expect(!(MessageHTMLNavigationFailure.shouldTriggerFallback(for: policyCancellation)))
    #expect(MessageHTMLNavigationFailure.shouldTriggerFallback(for: failure))
  }
}

extension MessageHTMLPresentationTests {
  @Test
  func testPresentationPreparationCancelsDetachedSanitization() async {
    let body = MailboxMessageBody(text: "Readable fallback", html: "<p>Rich message</p>")
    let sanitizationStarted = DispatchSemaphore(value: 0)
    let allowSanitizationToFinish = DispatchSemaphore(value: 0)
    let preparation = Task {
      try await MessageHTMLPresentation.prepare(body: body) { _, _ in
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
      Issue.record("Cancelled preparation should not publish a presentation")
    } catch is CancellationError {
    } catch {
      Issue.record("Expected cancellation, got \(error)")
    }
  }
}

extension MessageHTMLPresentationTests {
  @Test
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

    #expect(contentIDs == ["normal@example.com", "important@example.com"])
  }

  @Test
  func testSanitizerHonorsOverridingVisibilityAndOpacityDeclarations() throws {
    let result = try requireValue(
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
      ))

    #expect(result.documentHTML.contains("Visible text"))
    #expect(result.documentHTML.contains("Visible spaced important text"))
    #expect(!(result.documentHTML.contains("Hidden text")))
    #expect(!(result.documentHTML.contains("Comment-hidden text")))
    #expect(!(result.documentHTML.contains("comment-hidden.png")))
    #expect(
      result.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/visible.png"
      ])
  }

  @Test
  func testSanitizerRejectsHiddenRemoteImagesAcrossCSSParsingForms() throws {
    let cases = [
      (#"visibility:h\69 dden"#, "escaped-visibility.gif"),
      (#"vis\69 bility:hidden"#, "escaped-property.gif"),
      ("display:/*;*/none", "comment-delimiter.png"),
      (#"font-family:"/*";visibility:hidden;foo:"*/""#, "string-comment-delimiter.png"),
    ]

    for (style, imageName) in cases {
      let result = try requireValue(
        MessageHTMLSanitizer.sanitize(
          """
          <p>Newsletter</p>
          <div style='\(style)'>
            <img src="https://tracker.example/\(imageName)">
          </div>
          """
        ))

      #expect(result.remoteImageReferences.isEmpty, Comment(rawValue: style))
      #expect(!(result.documentHTML.contains(imageName)), Comment(rawValue: style))
    }
  }

  @Test
  func testSanitizerAcceptsExponentNotationInDimensions() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <img src="https://images.example/exponent.gif"
             style="width:1px;width:1e2px;height:1px;height:1e2px">
        """
      ))

    #expect(
      result.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example/exponent.gif"
      ])
  }

  @Test
  func testSanitizerPreservesVisibleDescendantsOfHiddenWrappers() throws {
    let result = try requireValue(
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
      ))

    #expect(!(result.documentHTML.contains("Hidden preview")))
    #expect(result.documentHTML.contains("Receipt"))
    #expect(result.documentHTML.contains("Initial receipt"))
    #expect(!(result.documentHTML.contains("Hidden reverted receipt")))
    #expect(!(result.documentHTML.contains("tracker.example")))
    #expect(
      result.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/visible.png"
      ])
  }

  @Test
  func testSanitizerDoesNotPromoteVisibleDescendantsOfCollapsedTableRows() throws {
    let result = try requireValue(
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
      ))

    #expect(result.remoteImageReferences.isEmpty)
    #expect(!(result.documentHTML.contains("collapsed-row.png")))
  }

  @Test
  func testSanitizerDoesNotPromoteVisibleDescendantsOfCollapsedTableDisplay() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="display: table-row; visibility: collapse">
          <span style="visibility: visible">
            <img src="https://tracker.example/collapsed-row.png">
          </span>
        </div>
        """
      ))

    #expect(result.remoteImageReferences.isEmpty)
  }

  @Test
  func testSanitizerPromotesVisibleDescendantsOfCollapsedNonTableElements() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <div style="visibility: collapse">
          <span style="visibility: visible">Receipt</span>
        </div>
        """
      ))

    #expect(result.documentHTML.contains("Receipt"))
  }

  @Test
  func testSanitizerRemovesHiddenBranchesInsidePromotedVisibleSubtrees() throws {
    let result = try requireValue(
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
      ))

    #expect(result.documentHTML.contains("Receipt"))
    #expect(!(result.documentHTML.contains("Hidden details")))
    #expect(!(result.documentHTML.contains("tracker.example")))
    #expect(
      result.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/visible.png"
      ])
  }

  @Test
  func testSanitizerPromotesOnlyTopmostExplicitlyVisibleDescendant() throws {
    let result = try requireValue(
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
      ))

    #expect(result.documentHTML.components(separatedBy: "Receipt").count - 1 == 1)
    #expect(
      result.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/receipt.png"
      ])
  }

  @Test
  func testSanitizerDoesNotPromoteVisibleDescendantsOfOtherwiseHiddenWrappers() throws {
    for intermediateAttribute in [
      #"style="display: none""#,
      #"style="opacity: 0""#,
      #"style="width: 0""#,
      #"style="margin-left: -9999px""#,
      "hidden",
    ] {
      let result = try requireValue(
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
        ))

      #expect(
        result.remoteImageReferences.isEmpty,
        Comment(rawValue: intermediateAttribute)
      )
    }
  }

  @Test
  func testSanitizerHonorsPositiveMinimumOverZeroMaximum() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <div style="max-width: 0; min-width: 600px">
          Receipt
          <img src="https://images.example.com/receipt.png">
        </div>
        """
      ))

    #expect(result.documentHTML.contains("Receipt"))
    #expect(
      result.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/receipt.png"
      ])
  }

  @Test
  func testSanitizerHonorsPositiveMinimumOnZeroMaximumImage() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <img src="https://images.example.com/receipt.png"
             style="max-width: 0; min-width: 600px">
        """
      ))

    #expect(
      result.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/receipt.png"
      ])
  }

  @Test
  func testSanitizerIgnoresInvalidVisibilityAndOpacityOverrides() throws {
    let result = try requireValue(
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
      ))

    #expect(result.remoteImageReferences.isEmpty)
  }

  @Test
  func testSanitizerHonorsCalculatedOpacityOverride() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="opacity: 0; opacity: calc(1)">
          <img src="https://images.example.com/visible.png">
        </div>
        """
      ))

    #expect(
      result.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/visible.png"
      ])
  }

  @Test
  func testSanitizerLetsUnresolvedVariableOpacityOverrideHiddenDeclaration() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <div style="opacity:0;opacity:var(--missing)">
          <img src="https://images.example.com/variable-opacity.png">
        </div>
        """
      ))

    #expect(
      result.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/variable-opacity.png"
      ])
  }

  @Test
  func testSanitizerResolvesDefinedVariableBeforeOpacityFallback() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <div style="--o:1;opacity:var(--o,0)">
          <img src="https://images.example.com/defined-variable-opacity.png">
        </div>
        <div style="--o:1">
          <div style="opacity:var(--o,0)">
            <img src="https://images.example.com/inherited-variable-opacity.png">
          </div>
        </div>
        """
      ))

    #expect(
      result.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/defined-variable-opacity.png",
        "https://images.example.com/inherited-variable-opacity.png",
      ])
  }

  @Test
  func testSanitizerRemovesContentHiddenByDefinedVariableOpacity() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="--o:0;opacity:var(--o)">
          <img src="https://tracker.example/defined-zero-opacity.png">
        </div>
        <div style="--o:0">
          <div style="opacity:var(--o)">
            <img src="https://tracker.example/inherited-zero-opacity.png">
          </div>
        </div>
        <div style="--o:initial;opacity:var(--o,0)">
          <img src="https://tracker.example/invalid-variable-opacity.png">
        </div>
        """
      ))

    #expect(result.remoteImageReferences.isEmpty)
  }

  @Test
  func testSanitizerMatchesCustomPropertyNamesCaseSensitively() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="--O:1;opacity:var(--o,0)">
          <img src="https://tracker.example/case-sensitive-variable.png">
        </div>
        """
      ))

    #expect(result.remoteImageReferences.isEmpty)
    #expect(!(result.documentHTML.contains("case-sensitive-variable.png")))
  }

  @Test
  func testSanitizerRemovesConstantCalculatedZeroOpacityContent() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="opacity: calc(1 - 1)">
          <img src="https://tracker.example/hidden.png">
        </div>
        """
      ))

    #expect(result.remoteImageReferences.isEmpty)
  }

  @Test
  func testSanitizerRejectsNonCSSCalculatedOpacityOverrides() throws {
    for opacity in ["calc(nan)", "calc(infinity)", "calc(0x1p4)"] {
      let result = try requireValue(
        MessageHTMLSanitizer.sanitize(
          """
          <p>Newsletter</p>
          <div style="opacity:0;opacity:\(opacity)">
            <img src="https://tracker.example/hidden.png">
          </div>
          """
        ))

      #expect(result.remoteImageReferences.isEmpty, Comment(rawValue: opacity))
    }
  }

  @Test
  func testSanitizerRemovesConstantFunctionZeroOpacityContent() throws {
    for opacity in [
      "min(0, 0)", "max(0%, 0)", "clamp(0, 0%, 1)",
      "min(max(0, 0), 1)", "calc(min(0, 0))",
    ] {
      let result = try requireValue(
        MessageHTMLSanitizer.sanitize(
          """
          <p>Newsletter</p>
          <div style="opacity: \(opacity)">
            <img src="https://tracker.example/hidden.png">
          </div>
          """
        ))

      #expect(result.remoteImageReferences.isEmpty, Comment(rawValue: opacity))
    }
  }

  @Test
  func testSanitizerRemovesZeroOpacityVariableFallbackContent() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="opacity:var(--missing,0)">
          <img src="https://tracker.example/variable-opacity.gif">
        </div>
        """
      ))

    #expect(result.remoteImageReferences.isEmpty)
    #expect(!(result.documentHTML.contains("variable-opacity.gif")))
  }

  @Test
  func testSanitizerBoundsNestedVariableOpacityFallbacks() throws {
    let opacity = (0..<1_000).reduce("0") { value, _ in "var(--missing,\(value))" }
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <div style="opacity:\(opacity)">
          <img src="https://images.example.com/deep-opacity.png">
        </div>
        """
      ))

    #expect(
      result.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/deep-opacity.png"
      ])
  }

  @Test
  func testSanitizerBoundsNestedFitContentDimensions() throws {
    let dimension = (0..<1_000).reduce("1px") { value, _ in "fit-content(\(value))" }
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <img src="https://tracker.example/deep-fit-content.gif"
             style="width:0;width:\(dimension);height:0;height:\(dimension)">
        """
      ))

    #expect(result.remoteImageReferences.isEmpty)
    #expect(!(result.documentHTML.contains("deep-fit-content.gif")))
  }

  @Test
  func testSanitizerDoesNotParseDeclarationsInsideQuotedStyleValues() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <img style='font-family:"x;display:none;y"'
             src="https://images.example.com/quoted-semicolon.png">
        """
      ))

    #expect(
      result.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/quoted-semicolon.png"
      ])
  }

  @Test
  func testSanitizerHonorsOverridingReadableHiddenDeclarations() throws {
    for style in [
      "display: none; display: block",
      "font-size: 0; font-size: 14px",
      "line-height: 0 !important; line-height: 1.5 !important",
      "margin: -9999px; margin: 0",
      "margin-left: -9999px; margin-left: 0 !important",
    ] {
      let result = try requireValue(
        MessageHTMLSanitizer.sanitize(#"<div style="\#(style)">Visible text</div>"#))

      #expect(result.documentHTML.contains("Visible text"), Comment(rawValue: style))
    }
  }

  @Test
  func testSanitizerIgnoresInvalidReadableLengthOverrides() throws {
    for style in [
      "font-size: 0; font-size: bogus",
      "margin-left: -9999px; margin-left: bogus",
    ] {
      #expect(
        try MessageHTMLSanitizer.sanitize(
          #"<div style="\#(style)">Hidden text</div>"#
        ) == nil, Comment(rawValue: style))
    }
  }

  @Test
  func testSanitizerIgnoresInvalidCompoundDisplayOverride() throws {
    #expect(
      try MessageHTMLSanitizer.sanitize(
        #"<div style="display: none; display: none block">Hidden text</div>"#
      ) == nil)
  }

  @Test
  func testSanitizerIgnoresStandaloneFlowDisplayOverride() throws {
    #expect(
      try MessageHTMLSanitizer.sanitize(
        #"<div style="display: none; display: flow">Hidden text</div>"#
      ) == nil)
  }

  @Test
  func testSanitizerPreservesVisibleContentWithInvalidZeroLengthOverride() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        #"<div style="height: 12px; height: 0abc">Visible text</div>"#
      ))

    #expect(result.documentHTML.contains("Visible text"))
  }

  @Test
  func testSanitizerIgnoresInvalidMaximumDimensionOverrides() throws {
    for style in [
      "max-height: 0; max-height: normal",
      "max-width: 0; max-width: auto",
      "height: 0; height: 5",
    ] {
      let result = try requireValue(
        MessageHTMLSanitizer.sanitize(
          """
          <p>Newsletter</p>
          <img style="\(style)" src="https://tracker.example/hidden.png">
          """
        ))

      #expect(result.remoteImageReferences.isEmpty, Comment(rawValue: style))
    }
  }

  @Test
  func testSanitizerRemovesCalculatedZeroDimensionImages() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <img style="max-width: calc(0px + 0px)"
             src="https://tracker.example/hidden.png">
        """
      ))

    #expect(result.remoteImageReferences.isEmpty)
  }

  @Test
  func testSanitizerHonorsOverridingMaximumDimensionDeclarations() throws {
    let result = try requireValue(
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
      ))

    #expect(
      result.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/width.png", "https://images.example.com/height.png",
      ])
  }

  @Test
  func testSanitizerRetainsRemoteImageWithNonRenderingUnicodePreheader() throws {
    for text in ["&zwnj;", "&#847;"] {
      let result = try requireValue(
        MessageHTMLSanitizer.sanitize(
          """
          <div>\(text)</div>
          <img src="https://tracker.test/hero.png">
          """
        ))

      #expect(result.remoteImageReferences.count == 1)
    }
  }

  @Test
  func testSanitizerRetainsRemoteImageWithOffCanvasMarginShorthandPreheader() throws {
    for style in ["margin: 0 -9999px", "margin: 0 0 -9999px", "margin: 0 0 0 -9999px"] {
      let result = try requireValue(
        MessageHTMLSanitizer.sanitize(
          """
          <div style="\(style)">Hidden preview</div>
          <img src="https://tracker.test/hero.png">
          """
        ))

      #expect(result.remoteImageReferences.count == 1)
    }
  }

  @Test
  func testSanitizerChecksCancellationBetweenFullDocumentPasses() throws {
    var cancellationChecks = 0

    #expect {
      try MessageHTMLSanitizer.sanitize("<p>Readable</p>") {
        cancellationChecks += 1
        if cancellationChecks == 1 {
          throw CancellationError()
        }
      }
    } throws: { error in
      #expect(error is CancellationError)
      return true
    }
    #expect(cancellationChecks == 1)
  }

  @Test
  func testSanitizerChecksCancellationDuringQuotedReplyTraversal() throws {
    var cancellationChecks = 0

    #expect {
      try MessageHTMLSanitizer.sanitize(
        "<p>New reply</p><blockquote><p>Previous message</p></blockquote>",
        removesQuotedReplies: true
      ) {
        cancellationChecks += 1
        if cancellationChecks == 2 {
          throw CancellationError()
        }
      }
    } throws: { error in
      #expect(error is CancellationError)
      return true
    }
    #expect(cancellationChecks == 2)
  }

  @Test
  func testSanitizerHandlesDeeplyNestedHiddenTextInOneTraversal() throws {
    let depth = 2_000
    let html =
      String(repeating: #"<div style="visibility: hidden">"#, count: depth)
      + "Hidden preview"
      + String(repeating: "</div>", count: depth)
      + #"<img src="https://images.example.com/hero.png">"#

    let result = try requireValue(MessageHTMLSanitizer.sanitize(html))

    #expect(!(result.documentHTML.contains("Hidden preview")))
    #expect(
      result.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/hero.png"
      ])
  }

  @Test
  func testSanitizerResolvesVariableBackedVisibilityAndDisplayBeforeCleaning() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="--v:hidden;visibility:var(--v)">
          <img src="https://tracker.example/hidden-visibility.png">
        </div>
        <div style="--d:none;display:var(--d)">
          <img src="https://tracker.example/hidden-display.png">
        </div>
        """
      ))

    #expect(result.remoteImageReferences.isEmpty)
  }

  @Test
  func testSanitizerDecodesEscapedCustomPropertyNames() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        #"<img style="--\6f:1;opacity:var(--o,0)" src="https://images.example.com/visible.png">"#
      ))

    #expect(
      result.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/visible.png"
      ])
  }

  @Test
  func testSanitizerRetainsPartiallyVisibleNegativeOffsetImage() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        #"<img style="margin-left:-100px;width:600px;height:100px" src="https://images.example.com/visible.png">"#
      ))

    #expect(result.remoteImageReferences.count == 1)
  }

  @Test
  func testSanitizerRejectsAutoMaximumOverridesPerProperty() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <img style="width:600px;height:600px;max-width:1px;max-width:auto;max-height:1px;max-height:auto"
             src="https://tracker.example/hidden.png">
        """
      ))

    #expect(result.remoteImageReferences.isEmpty)
  }
}

extension MessageHTMLPresentationTests {
  @Test
  func testRemoteContentLoaderSkipsRequestsWhenPixelBudgetIsExhausted() async throws {
    let reference = RemoteMessageImageReference(
      identifier: "remote-image-0",
      url: try requireValue(URL(string: "https://images.example.com/hero.png"))
    )
    let presentation = SanitizedMessageHTML(
      documentHTML: #"<img data-unwired-remote-image="remote-image-0">"#,
      remoteImageReferences: [reference]
    )
    let loader = RemoteMessageContentLoader(
      maximumTotalPixelCount: 0,
      fetch: { _, _ in
        Issue.record("Pixel-exhausted content must not make a request")
        throw TestError.sanitizationFailed
      })

    let result = try await loader.load(presentation)

    #expect(result.loadedImageCount == 0)
    #expect(result.failedImageCount == 1)
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
      url: try requireValue(URL(string: "https://images.example.com/image-\($0)"))
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
  @Test
  func testSanitizerHandlesBoundedNestedPercentageDimensionResolution() throws {
    let wrappers = String(
      repeating:
        #"<div style="width:100%;max-width:100%;min-width:100%;height:100%;max-height:100%;min-height:100%">"#,
      count: 32
    )
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        #"<p>Newsletter</p><div style="width:1px;height:1px">"# + wrappers
          + #"<img src="https://tracker.example/pixel.gif" style="width:100%;height:100%">"#
          + String(repeating: "</div>", count: 33)
      ))

    #expect(result.remoteImageReferences.isEmpty)
  }

  @Test
  func testSanitizerRemovesConstantFunctionZeroDimensions() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <img style="width:min(0px, 0px)" src="https://tracker.example/pixel.gif">
        """
      ))

    #expect(result.remoteImageReferences.isEmpty)
  }

  @Test
  func testSanitizerRemovesNestedConstantFunctionZeroDimensions() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <img style="width:calc(min(0px, 0px))" src="https://tracker.example/pixel.gif">
        """
      ))

    #expect(result.remoteImageReferences.isEmpty)
  }

  @Test
  func testSanitizerResolvesPercentageDimensionsInMathFunctions() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="width:100px">
          <img style="width:min(1%, 50px);height:1px"
               src="https://tracker.example/min-percentage.gif">
          <img style="width:max(1%, 0px);height:1px"
               src="https://tracker.example/max-percentage.gif">
          <img style="width:clamp(0px, 1%, 50px);height:1px"
               src="https://tracker.example/clamp-percentage.gif">
        </div>
        """
      ))

    #expect(result.remoteImageReferences.isEmpty)
    #expect(!(result.documentHTML.contains("min-percentage.gif")))
    #expect(!(result.documentHTML.contains("max-percentage.gif")))
    #expect(!(result.documentHTML.contains("clamp-percentage.gif")))
  }

  @Test
  func testSanitizerDoesNotApplyTextIndentToRemoteImageBox() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <img style="text-indent:-100px" src="https://images.example.com/visible.png">
        """
      ))

    #expect(
      result.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/visible.png"
      ])
  }

  @Test
  func testSanitizerPromotesVisibleDescendantThroughRevertAncestor() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <div style="visibility:hidden"><span style="visibility:revert">
          <b style="visibility:visible">Receipt</b>
        </span></div>
        """
      ))

    #expect(result.documentHTML.contains("Receipt"))
  }

  @Test
  func testSanitizerIgnoresMaximumDimensionsOnOrdinaryInlineElements() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(#"<span style="max-width:0;max-height:0">Receipt</span>"#))

    #expect(result.documentHTML.contains("Receipt"))
  }

  @Test
  func testSanitizerIgnoresDimensionsOnOrdinaryInlineElements() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        #"<p>Order <span style="width:0;height:0">Receipt</span>"#
          + #"<span style="display:initial;width:0">Initial receipt</span></p>"#
      ))

    #expect(result.documentHTML.contains("Receipt"))
    #expect(result.documentHTML.contains("Initial receipt"))
  }

  @Test
  func testSanitizerTreatsDisplayContentsImagesAsHidden() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <img src="https://tracker.example/display-contents.png" style="display: contents">
        """
      ))

    #expect(result.remoteImageReferences.isEmpty)
    #expect(!(result.documentHTML.contains("display-contents.png")))
  }

  @Test
  func testSanitizerTreatsEscapedAndTableColumnDisplaysAsHidden() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        #"""
        <p>Newsletter</p>
        <img src="https://tracker.example/escaped-none.png" style="display:n\6f ne">
        <img src="https://tracker.example/table-column.png" style="display:table-column">
        <img src="https://tracker.example/table-column-group.png"
             style="display:table-column-group">
        <div style="display:table-column">
          <img src="https://tracker.example/table-column-wrapper.png">
        </div>
        <div style="display:table-column-group">
          <img src="https://tracker.example/table-column-group-wrapper.png">
        </div>
        """#
      ))

    #expect(result.remoteImageReferences.isEmpty)
    #expect(!(result.documentHTML.contains("escaped-none.png")))
    #expect(!(result.documentHTML.contains("table-column.png")))
    #expect(!(result.documentHTML.contains("table-column-group.png")))
    #expect(!(result.documentHTML.contains("table-column-wrapper.png")))
    #expect(!(result.documentHTML.contains("table-column-group-wrapper.png")))
  }

  @Test
  func testSanitizerLetsVariableDisplayOverrideHiddenDeclaration() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <div style="display:none;display:var(--missing)">
          <img src="https://images.example.com/variable-display.png">
        </div>
        """
      ))

    #expect(
      result.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/variable-display.png"
      ])

    let fallbackResult = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="display:none;display:var(--missing,none)">
          <img src="https://tracker.example/variable-display-fallback.png">
        </div>
        """
      ))
    #expect(fallbackResult.remoteImageReferences.isEmpty)
  }

  @Test
  func testSanitizerRemovesHiddenDisallowedWrapperBeforeCleaning() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <section hidden>
          <img src="https://tracker.example/hidden-section.png">
        </section>
        """
      ))

    #expect(result.remoteImageReferences.isEmpty)
  }

  @Test
  func testSanitizerDecodesEscapedDimensionUnits() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        #"""
        <p>Newsletter</p>
        <img src="https://tracker.example/escaped-unit.png"
             style="width:1\70 x;height:1\70 x">
        """#
      ))

    #expect(result.remoteImageReferences.isEmpty)
    #expect(!(result.documentHTML.contains("escaped-unit.png")))
  }

  @Test
  func testSanitizerPreservesEscapedLeadingDigitDimensionTokenTypes() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        #"""
        <p>Newsletter</p>
        <img src="https://images.example.com/escaped-leading-width.png"
             style="width:600px;width:\31 px;height:600px">
        <img src="https://images.example.com/escaped-leading-height.png"
             style="width:600px;height:600px;height:\31 px">
        """#
      ))

    #expect(
      result.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/escaped-leading-width.png",
        "https://images.example.com/escaped-leading-height.png",
      ])
  }

  @Test
  func testSanitizerResolvesPercentageDimensionsThroughInitialInlineDisplay() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="width:1px;height:1px">
          <span style="display:initial">
            <img src="https://tracker.example/pixel.gif" style="width:100%;height:100%">
          </span>
        </div>
        """
      ))

    #expect(result.remoteImageReferences.isEmpty)
  }

  @Test
  func testSanitizerAccountsForAutoBlockMarginsInPercentageDimensions() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="width:3px">
          <div style="margin:0 1px">
            <img src="https://tracker.example/pixel.gif" style="width:100%;height:1px">
          </div>
        </div>
        """
      ))

    #expect(result.remoteImageReferences.isEmpty)
  }

  @Test
  func testSanitizerAccountsForFunctionalMarginsInPercentageDimensions() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="width:7px">
          <div style="margin:0 calc(1px + 2px)">
            <img src="https://tracker.example/functional-margin.gif"
                 style="width:100%;height:1px">
          </div>
        </div>
        """
      ))

    #expect(result.remoteImageReferences.isEmpty)
    #expect(!(result.documentHTML.contains("functional-margin.gif")))
  }

  @Test
  func testSanitizerAccountsForPercentageMathFunctionsInMargins() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="width:100px">
          <div style="margin:0 min(49.5%, 300px)">
            <img src="https://tracker.example/functional-percentage-margin.gif"
                 style="width:100%;height:1px">
          </div>
        </div>
        """
      ))

    #expect(result.remoteImageReferences.isEmpty)
    #expect(!(result.documentHTML.contains("functional-percentage-margin.gif")))
  }

  @Test
  func testSanitizerRejectsNonFiniteCalculatedInsets() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="width:100px">
          <div style="margin-right:max(1e400%, 1px);margin-left:min(-1e400%, -1px)">
            <img src="https://images.example.com/visible.gif"
                 style="width:100%;height:100px">
          </div>
        </div>
        """
      ))

    #expect(
      result.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/visible.gif"
      ])
  }

  @Test
  func testSanitizerAccountsForPercentageMarginsInAutoBlockWidths() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="width:100px">
          <div style="margin:0 49.5%">
            <img src="https://tracker.example/percentage-margin.gif"
                 style="width:100%;height:1px">
          </div>
        </div>
        """
      ))

    #expect(result.remoteImageReferences.isEmpty)
    #expect(!(result.documentHTML.contains("percentage-margin.gif")))
  }

  @Test
  func testSanitizerTreatsCenterAsAnAutoWidthBlock() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="width:3px">
          <center style="margin:0 1px">
            <img src="https://tracker.example/center.gif" style="width:100%;height:1px">
          </center>
        </div>
        """
      ))

    #expect(result.remoteImageReferences.isEmpty)
    #expect(!(result.documentHTML.contains("center.gif")))
  }

  @Test
  func testSanitizerTreatsListItemsAsAutoWidthBlocks() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="width:3px">
          <ul>
            <li style="margin:0 1px">
              <img src="https://tracker.example/list-item.gif" style="width:100%;height:1px">
            </li>
          </ul>
        </div>
        """
      ))

    #expect(result.remoteImageReferences.isEmpty)
    #expect(!(result.documentHTML.contains("list-item.gif")))
  }

  @Test
  func testSanitizerAccountsForAutoBlockBordersInPercentageDimensions() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="width:3px">
          <div style="border-left:1px solid;border-right:1px solid">
            <img src="https://tracker.example/pixel.gif" style="width:100%;height:1px">
          </div>
        </div>
        """
      ))

    #expect(result.remoteImageReferences.isEmpty)
  }

  @Test
  func testSanitizerAccountsForDefaultBorderWidthsInPercentageDimensions() throws {
    let result = try requireValue(
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
      ))

    #expect(result.remoteImageReferences.isEmpty)
    #expect(!(result.documentHTML.contains("default-border.gif")))
  }

  @Test
  func testSanitizerAccountsForNamedBorderColorsInPercentageDimensions() throws {
    let result = try requireValue(
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
      ))

    #expect(result.remoteImageReferences.isEmpty)
    #expect(!(result.documentHTML.contains("named-border.gif")))
  }

  @Test
  func testSanitizerAccountsForFunctionalBorderColorsInPercentageDimensions() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="width:7px">
          <div style="border-left:solid rgb(0 0 0);border-right:solid rgb(0 0 0)">
            <img src="https://tracker.example/functional-border.gif"
                 style="width:100%;height:1px">
          </div>
        </div>
        """
      ))

    #expect(result.remoteImageReferences.isEmpty)
    #expect(!(result.documentHTML.contains("functional-border.gif")))
  }

  @Test
  func testSanitizerAccountsForSystemBorderColorsInPercentageDimensions() throws {
    for color in ["accentcolor", "canvastext", "linktext"] {
      let result = try requireValue(
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
        ))

      #expect(result.remoteImageReferences.isEmpty, Comment(rawValue: color))
      #expect(
        !(result.documentHTML.contains("system-border.gif")),
        Comment(rawValue: color)
      )
    }
  }

  @Test
  func testSanitizerIgnoresInvalidBorderShorthandsInPercentageDimensions() throws {
    let result = try requireValue(
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
      ))

    #expect(result.remoteImageReferences.count == 1)
    #expect(
      result.remoteImageReferences.first?.url.absoluteString == "https://images.example/visible.gif"
    )
    #expect(result.documentHTML.contains(RemoteMessageContentMarkup.attribute))
    #expect(!(result.documentHTML.contains("visible.gif")))
  }

  @Test
  func testSanitizerIgnoresInvalidFunctionalBorderColorsInPercentageDimensions() throws {
    let result = try requireValue(
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
      ))

    #expect(
      result.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example/visible-functional-color.gif"
      ])
  }

  @Test
  func testSanitizerResetsOmittedBorderStyleInLaterShorthand() throws {
    let result = try requireValue(
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
      ))

    #expect(
      result.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example/visible-reset-border.gif"
      ])
  }

  @Test
  func testSanitizerAppliesCSSWideBorderShorthandResets() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="width:601px">
          <div style="border-left:300px solid;border-right:300px solid;border:initial">
            <img src="https://images.example/visible-reset-border.gif"
                 style="width:100%;height:1px">
          </div>
        </div>
        """
      ))

    #expect(
      result.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example/visible-reset-border.gif"
      ])
  }

  @Test
  func testSanitizerDoesNotResetInheritedBorderShorthand() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="width:601px">
          <div style="border-left:300px solid;border-right:300px solid;border:inherit">
            <img src="https://tracker.example/inherited-border.gif" style="width:100%;height:1px">
          </div>
        </div>
        """
      ))

    #expect(result.remoteImageReferences.isEmpty)
  }

  @Test
  func testSanitizerResolvesInheritedTrackingPixelDimensions() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="width:1px;height:1px">
          <img src="https://tracker.example/inherited.gif"
               style="width:inherit;height:inherit">
        </div>
        """
      ))

    #expect(result.remoteImageReferences.isEmpty)
    #expect(!(result.documentHTML.contains("inherited.gif")))
  }

  @Test
  func testSanitizerResolvesInheritedPercentagesForTheChildContainingBlock() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="width:4px">
          <div style="width:50%">
            <img src="https://tracker.example/inherited-percentage.gif"
                 style="width:inherit;height:1px">
          </div>
        </div>
        """
      ))

    #expect(result.remoteImageReferences.isEmpty)
    #expect(!(result.documentHTML.contains("inherited-percentage.gif")))
  }

  @Test
  func testSanitizerAccountsForFontRelativeInsetsInPercentageDimensions() throws {
    let result = try requireValue(
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
      ))

    #expect(result.remoteImageReferences.isEmpty)
    #expect(!(result.documentHTML.contains("font-relative-inset.gif")))
  }

  @Test
  func testSanitizerTokenizesFunctionalPaddingInPercentageDimensions() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="width:7px">
          <div style="padding:0 calc(1px + 2px)">
            <img src="https://tracker.example/functional-padding.gif"
                 style="width:100%;height:1px">
          </div>
        </div>
        """
      ))

    #expect(result.remoteImageReferences.isEmpty)
    #expect(!(result.documentHTML.contains("functional-padding.gif")))
  }

  @Test
  func testSanitizerResolvesSmallFontTermsInCalculatedPercentageDimensions() throws {
    // 0.00001em at 16px plus 1% of 99.984px equals the one-pixel threshold.
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="width:99.984px;font-size:16px">
          <img src="https://tracker.example/small-font-term.gif"
               style="width:calc(0.00001em + 1%);height:1px">
        </div>
        """
      ))

    #expect(result.remoteImageReferences.isEmpty)
    #expect(!(result.documentHTML.contains("small-font-term.gif")))
  }

  @Test
  func testSanitizerAccountsForKeywordBorderWidthsInPercentageDimensions() throws {
    let result = try requireValue(
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
      ))

    #expect(result.remoteImageReferences.isEmpty)
    #expect(!(result.documentHTML.contains("keyword-border.gif")))
  }

  @Test
  func testSanitizerIgnoresInactiveBorderWidthsInPercentageDimensions() throws {
    let result = try requireValue(
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
      ))

    #expect(
      result.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/inactive-border.png"
      ])
  }

  @Test
  func testSanitizerRejectsNegativeBorderWidthOverrides() throws {
    let result = try requireValue(
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
      ))

    #expect(result.remoteImageReferences.isEmpty)
    #expect(!(result.documentHTML.contains("negative-border.gif")))
  }

  @Test
  func testSanitizerIgnoresInvalidNegativePaddingOverride() throws {
    let result = try requireValue(
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
      ))

    #expect(result.remoteImageReferences.isEmpty)
    #expect(!(result.documentHTML.contains("negative-padding.gif")))
  }

  @Test
  func testSanitizerIncludesAncestorPaddingWhenEvaluatingNegativeOffsets() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="padding-left:200px">
          <span>
            <img src="https://images.example.com/visible.png" style="margin-left:-100px">
          </span>
        </div>
        """
      ))

    #expect(
      result.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/visible.png"
      ])
  }

  @Test
  func testSanitizerIncludesAncestorMarginsWhenEvaluatingNegativeOffsets() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="margin-left:200px">
          <img src="https://images.example.com/visible-margin-offset.png"
               style="margin-left:-100px;width:600px;height:100px">
        </div>
        """
      ))

    #expect(
      result.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/visible-margin-offset.png"
      ])
  }

  @Test
  func testSanitizerIncludesAncestorBordersWhenEvaluatingNegativeOffsets() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="border-top:200px solid">
          <div style="margin-top:-100px">
            <img src="https://images.example.com/visible-border-offset.png">
          </div>
        </div>
        """
      ))

    #expect(
      result.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/visible-border-offset.png"
      ])
  }

  @Test
  func testSanitizerRetainsImagesOffsetByPrecedingInlineFlow() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <span style="display:inline-block;width:200px"></span>
        <img src="https://images.example.com/visible-inline-offset.png"
             style="margin-left:-100px">
        """
      ))

    #expect(
      result.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/visible-inline-offset.png"
      ])
  }

  @Test
  func testSanitizerRetainsImageOffsetByDefaultInlineReplacedFlow() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <img src="cid:hero" width="200"><img
          src="https://images.example.com/visible-replaced-offset.png"
          style="margin-left:-100px">
        """
      ))

    #expect(
      result.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/visible-replaced-offset.png"
      ])
  }

  @Test
  func testSanitizerRetainsImageOffsetByPrecedingTextFlow() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <div>Order summary<img src="https://images.example.com/visible-text-offset.png"
             style="margin-left:-100px"></div>
        """
      ))

    #expect(
      result.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/visible-text-offset.png"
      ])
  }

  @Test
  func testSanitizerRejectsCalculatedDimensionsWithoutOperatorWhitespace() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p><img src="https://images.example.com/hero.png"
          style="width:600px;width:calc(1px+0px);height:600px;height:calc(1px+0px)">
        <img src="https://images.example.com/banner.png"
          style="width:600px;width:calc(0px+0px);height:600px;height:calc(0px+0px)">
        """
      ))

    #expect(
      result.remoteImageReferences.map(\.url.absoluteString) == [
        "https://images.example.com/hero.png", "https://images.example.com/banner.png",
      ])
  }

  @Test
  func testSanitizerRejectsMalformedCalculatedDimensionOverrides() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <img src="https://tracker.example/malformed-width.gif"
             style="width:1px;width:calc(bogus);height:1px">
        <img src="https://tracker.example/malformed-height.gif"
             style="width:1px;height:1px;height:calc(bogus)">
        <img src="https://tracker.example/incomplete-width.gif"
             style="width:1px;width:calc(1px +);height:1px">
        <img src="https://tracker.example/incomplete-height.gif"
             style="width:1px;height:1px;height:calc(1px +)">
        <img src="https://tracker.example/leading-operator.gif"
             style="width:1px;width:calc(*1px);height:1px">
        """
      ))

    #expect(result.remoteImageReferences.isEmpty)
    #expect(!(result.documentHTML.contains("malformed-width.gif")))
    #expect(!(result.documentHTML.contains("malformed-height.gif")))
    #expect(!(result.documentHTML.contains("incomplete-width.gif")))
    #expect(!(result.documentHTML.contains("incomplete-height.gif")))
    #expect(!(result.documentHTML.contains("leading-operator.gif")))
  }

  @Test
  func testSanitizerRejectsNegativeDimensionOverrides() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <img src="https://tracker.example/negative-dimensions.gif"
             style="width:1px;width:-1px;height:1px;height:-1px">
        """
      ))

    #expect(result.remoteImageReferences.isEmpty)
    #expect(!(result.documentHTML.contains("negative-dimensions.gif")))
  }

  @Test
  func testSanitizerResolvesNestedAutoWidthsForPercentageDimensions() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Newsletter</p>
        <div style="width:3px">
          <div>
            <div style="margin:0 1px">
              <img src="https://tracker.example/nested-auto-width.gif"
                   style="width:100%;height:1px">
            </div>
          </div>
        </div>
        """
      ))

    #expect(result.remoteImageReferences.isEmpty)
    #expect(!(result.documentHTML.contains("nested-auto-width.gif")))
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
  let errorExpectation: TestExpectation
  var error: Error?

  init(expectation: TestExpectation) {
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
