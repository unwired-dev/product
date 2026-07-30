import XCTest

@testable import unwired_mail

final class MessageAppearanceTests: XCTestCase {
  func testReadingAppearanceStylesSanitizedHTMLForDarkHighContrastSerifText() throws {
    let sanitized = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        """
        <p style="font-family: Courier; font-size: 0.9em">Readable message</p>
        """
      )
    )

    let document = MessageHTMLDocument.styled(
      sanitized,
      style: MessageHTMLStyle(
        colorScheme: .dark,
        increasedContrast: true,
        readingTextSize: .large,
        typeface: .systemSerif
      )
    )

    XCTAssertTrue(document.contains(":root { color-scheme: dark; }"))
    XCTAssertTrue(document.contains("background: #000;"))
    XCTAssertTrue(document.contains("color: #fff;"))
    XCTAssertTrue(document.contains("-webkit-text-size-adjust: 112.5%;"))
    XCTAssertTrue(document.contains("font-size: 112.5%;"))
    XCTAssertTrue(document.contains("font-family: ui-serif, Georgia, serif !important;"))
    XCTAssertTrue(document.contains("font-family:Courier"))
    XCTAssertTrue(document.contains("font-size:0.9em"))
  }

  func testSenderFormattingKeepsSanitizedFontsWhileApplyingReadingSizeAndTheme() throws {
    let sanitized = try XCTUnwrap(
      MessageHTMLSanitizer.sanitize(
        "<p style=\"font-family: Courier\">Readable message</p>"
      )
    )

    let document = MessageHTMLDocument.styled(
      sanitized,
      style: MessageHTMLStyle(
        colorScheme: .light,
        increasedContrast: false,
        readingTextSize: .small,
        typeface: .senderFormatting
      )
    )

    XCTAssertTrue(document.contains("font-size: 87.5%;"))
    XCTAssertTrue(document.contains("-webkit-text-size-adjust: 87.5%;"))
    XCTAssertTrue(document.contains("<p style=\"font-family:Courier\">"))
    XCTAssertFalse(document.contains("body * { font-family:"))
  }
}
