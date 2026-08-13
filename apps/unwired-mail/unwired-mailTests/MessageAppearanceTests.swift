import Foundation
import Testing

@testable import unwired_mail

@Suite(.serialized)
final class MessageAppearanceTests {
  @Test
  func testMessageRequiresLoadedVisibleBodyBeforeMarkingRead() {
    let viewport = CGRect(x: 0, y: 0, width: 600, height: 500)
    let visibleBody = CGRect(x: 20, y: 100, width: 560, height: 300)
    let bodyBelowViewport = CGRect(x: 20, y: 520, width: 560, height: 300)

    #expect(
      !MailShellMessageReadVisibility.isEligible(
        isBodyLoaded: false,
        bodyFrame: visibleBody,
        viewportFrame: viewport
      )
    )
    #expect(
      MailShellMessageReadVisibility.isEligible(
        isBodyLoaded: true,
        bodyFrame: visibleBody,
        viewportFrame: viewport
      )
    )
    #expect(
      !MailShellMessageReadVisibility.isEligible(
        isBodyLoaded: true,
        bodyFrame: bodyBelowViewport,
        viewportFrame: viewport
      )
    )
  }

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
    #expect(document.contains("background: transparent;"))
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
