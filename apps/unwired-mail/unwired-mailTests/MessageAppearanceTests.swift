import Foundation
import Testing

@testable import unwired_mail

@Suite(.serialized)
final class MessageAppearanceTests {
  @Test
  func testReadingAppearanceStylesSanitizedHTMLForDarkHighContrastSerifText() throws {
    let sanitized = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p style="font-family: Courier; font-size: 0.9em">Readable message</p>
        """
      ))

    let document = MessageHTMLDocument.styled(
      sanitized,
      style: MessageHTMLStyle(
        colorScheme: .dark,
        increasedContrast: true,
        readingTextSize: .large,
        typeface: .systemSerif
      )
    )

    #expect(document.contains(":root { color-scheme: dark; }"))
    #expect(document.contains("background: #000;"))
    #expect(document.contains("color: #fff;"))
    #expect(document.contains("-webkit-text-size-adjust: 112.5%;"))
    #expect(!(document.contains("font-size: 112.5%;")))
    #expect(document.contains("font-family: ui-serif, Georgia, serif !important;"))
    #expect(document.contains("font-family:Courier"))
    #expect(document.contains("font-size:0.9em"))
  }

  @Test
  func testSenderFormattingKeepsSanitizedFontsWhileApplyingReadingSizeAndTheme() throws {
    let sanitized = try requireValue(
      MessageHTMLSanitizer.sanitize(
        "<p style=\"font-family: Courier\">Readable message</p>"
      ))

    let document = MessageHTMLDocument.styled(
      sanitized,
      style: MessageHTMLStyle(
        colorScheme: .light,
        increasedContrast: false,
        readingTextSize: .small,
        typeface: .senderFormatting
      )
    )

    #expect(!(document.contains("font-size: 87.5%;")))
    #expect(document.contains("-webkit-text-size-adjust: 87.5%;"))
    #expect(document.contains("<p style=\"font-family:Courier\">"))
    #expect(!(document.contains("body * { font-family:")))
  }
}
