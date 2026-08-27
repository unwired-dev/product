import SwiftUI

/// Shows original and translated mail together without implying provider-content replacement.
struct MailTranslationComparisonView: View {
  let result: MailTranslationResult

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    let layout =
      dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
      : AnyLayout(HStackLayout(alignment: .top, spacing: 16))

    layout {
      VStack(alignment: .leading, spacing: 8) {
        Text("Original")
          .font(.headline)
        Text(languageName(result.sourceLanguage))
          .font(.subheadline)
          .foregroundStyle(.secondary)
        Text(result.sourceText)
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .background(.regularMaterial, in: .rect(cornerRadius: 10))

      VStack(alignment: .leading, spacing: 8) {
        Text("Translation")
          .font(.headline)
        Text(languageName(result.targetLanguage))
          .font(.subheadline)
          .foregroundStyle(.secondary)
        Text(result.targetText)
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .background(.regularMaterial, in: .rect(cornerRadius: 10))
    }
  }

  private func languageName(_ language: Locale.Language) -> String {
    Locale.current.localizedString(forIdentifier: language.minimalIdentifier)
      ?? language.minimalIdentifier
  }
}
