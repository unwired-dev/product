import Foundation
import Observation
import SwiftSoup

extension MessageHTMLSanitizer {
  static func sourceContent(in document: Document) throws -> (
    hasText: Bool,
    hasExplicitlyHiddenText: Bool
  ) {
    let hasText = try !document.text().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let hiddenTextPattern = #"(?:^|;)\s*display\s*:\s*none(?:\s*!important)?\s*(?:;|$)"#
    let hasExplicitlyHiddenText = try document.select("[hidden], [style]").contains { element in
      let elementHasText = try !element.text().trimmingCharacters(in: .whitespacesAndNewlines)
        .isEmpty
      let style = try element.attr("style")
      return elementHasText
        && (element.hasAttr("hidden")
          || style.range(
            of: hiddenTextPattern,
            options: [.regularExpression, .caseInsensitive]
          ) != nil)
    }
    return (hasText, hasExplicitlyHiddenText)
  }
}

struct RemoteMessageContentLoadResult: Equatable, Sendable {
  let failedImageCount: Int
  let html: SanitizedMessageHTML
  var loadedByteCount = 0
  let loadedImageCount: Int
  var loadedPixelCount = 0
}

enum RemoteMessageContentState: Equatable {
  case blocked
  case failed(Int)
  case loading

  var failedImageCount: Int? {
    guard case .failed(let count) = self else { return nil }
    return count
  }
}

@MainActor
@Observable
final class RemoteMessageContentPresentation {
  private(set) var loadRequest: UUID?
  private(set) var loadedHTML: SanitizedMessageHTML?
  private(set) var state = RemoteMessageContentState.blocked

  func displayedHTML(originalHTML: SanitizedMessageHTML) -> SanitizedMessageHTML {
    loadedHTML ?? originalHTML
  }

  func requestLoad() {
    loadedHTML = nil
    state = .loading
    loadRequest = UUID()
  }

  func load(
    originalHTML: SanitizedMessageHTML,
    using loader: (SanitizedMessageHTML) async throws -> RemoteMessageContentLoadResult
  ) async {
    guard loadRequest != nil, state == .loading else { return }
    do {
      let result = try await loader(originalHTML)
      try Task.checkCancellation()
      loadedHTML = result.html
      state =
        result.failedImageCount == 0
        ? .blocked
        : .failed(result.failedImageCount)
    } catch is CancellationError {
    } catch {
      state = .failed(originalHTML.remoteImageReferences.count)
    }
  }

  func reset() {
    loadRequest = nil
    loadedHTML = nil
    state = .blocked
  }
}
