import Foundation

/// Public product metadata displayed by About without account or environment details.
struct AboutAppInformation: Equatable {
  let appName: String
  let version: String
  let build: String
  let copyrightNotice: String

  /// The published privacy notice for Unwired products.
  static let privacyPolicyURL = makeURL("https://www.unwired.dev/privacy")

  /// The published Terms of Use destination for Unwired Mail.
  static let termsOfUseURL = makeURL("https://www.unwired.dev/terms")

  /// The official Unwired Mail product page.
  static let productWebsiteURL = makeURL("https://www.unwired.dev/unwired-mail")

  /// The public support contact published by Unwired.
  static let supportURL = makeURL("mailto:silhan@unwired.dev")

  /// Creates display metadata from explicit public values.
  init(
    appName: String,
    version: String,
    build: String,
    copyrightYear: Int
  ) {
    self.appName = appName
    self.version = version
    self.build = build
    copyrightNotice = "Copyright © \(copyrightYear) Unwired, s.r.o."
  }

  /// Returns display metadata for the current app bundle and date.
  static func current(
    bundle: Bundle = .main,
    date: Date = Date(),
    calendar: Calendar = .current
  ) -> Self {
    Self(
      appName: bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        ?? "Unwired Mail",
      version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? "Unknown",
      build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown",
      copyrightYear: calendar.component(.year, from: date)
    )
  }

  private static func makeURL(_ value: String) -> URL {
    guard let url = URL(string: value) else {
      preconditionFailure("Invalid About URL: \(value)")
    }
    return url
  }
}
