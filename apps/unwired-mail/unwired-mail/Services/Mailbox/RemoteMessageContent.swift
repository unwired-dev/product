import Foundation
import SwiftSoup

struct RemoteMessageImageReference: Equatable, Sendable {
  let identifier: String
  let url: URL
}

enum RemoteMessageContentMarkup {
  static let attribute = "data-unwired-remote-image"

  static func recordReferences(in document: Document) throws -> [RemoteMessageImageReference] {
    for element in try document.select("[\(attribute)]") {
      try element.removeAttr(attribute)
    }
    var references: [RemoteMessageImageReference] = []
    var referencesByURL: [URL: RemoteMessageImageReference] = [:]
    for element in try document.select("img[src]") {
      let source = try element.attr("src").trimmingCharacters(in: .whitespacesAndNewlines)
      guard let url = URL(string: source),
        let scheme = url.scheme?.lowercased(),
        ["http", "https"].contains(scheme),
        url.host != nil,
        url.user == nil,
        url.password == nil
      else {
        continue
      }
      let requestURL = RemoteMessageContentPolicy.requestEquivalentURL(url)
      try element.removeAttr("src")
      guard
        !MessageHTMLSanitizer.hasZeroDimension(element),
        !hasDeclaredTrackingPixel(element)
      else {
        continue
      }
      let reference: RemoteMessageImageReference
      if let existingReference = referencesByURL[requestURL] {
        reference = existingReference
      } else {
        reference = RemoteMessageImageReference(
          identifier: "remote-image-\(references.count)",
          url: requestURL
        )
        references.append(reference)
        referencesByURL[requestURL] = reference
      }
      try element.attr(attribute, reference.identifier)
    }
    return references
  }

  private static func hasDeclaredTrackingPixel(_ element: Element) -> Bool {
    let onePixelPattern = #"^0*1(?:\.0*)?(?:px)?$"#
    let style = (try? element.attr("style")) ?? ""
    return ["width", "height"].allSatisfy { dimension in
      let value = ((try? element.attr(dimension)) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return
        value.range(of: onePixelPattern, options: [.regularExpression, .caseInsensitive]) != nil
        || style.range(
          of: #"(?:^|;)\s*"# + dimension
            + #"\s*:\s*0*1(?:\.0*)?(?:px)?(?:\s*!important)?\s*(?:;|$)"#,
          options: [.regularExpression, .caseInsensitive]
        ) != nil
    }
  }

  static func retainedReferences(
    _ references: [RemoteMessageImageReference],
    in document: Document
  ) throws -> [RemoteMessageImageReference] {
    let identifiers = Set(
      try document.select("[\(attribute)]").map {
        try $0.attr(attribute)
      }
    )
    return references.filter { identifiers.contains($0.identifier) }
  }

  static func occurrenceCounts(in html: SanitizedMessageHTML) -> [String: Int] {
    guard let document = try? SwiftSoup.parse(html.documentHTML),
      let elements = try? document.select("[\(attribute)]")
    else {
      return [:]
    }
    return elements.reduce(into: [:]) { counts, element in
      guard let identifier = try? element.attr(attribute), !identifier.isEmpty else { return }
      counts[identifier, default: 0] += 1
    }
  }
}

struct RemoteMessageImage: Equatable, Sendable {
  let data: Data
  let identifier: String
  let mimeType: String
}

enum RemoteMessageImageResolver {
  static func resolve(
    _ html: SanitizedMessageHTML,
    images: [RemoteMessageImage]
  ) -> SanitizedMessageHTML {
    guard !images.isEmpty, let document = try? SwiftSoup.parse(html.documentHTML) else {
      return html
    }
    let imagesByIdentifier = Dictionary(
      images.map { ($0.identifier, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    guard
      let elements = try? document.select("[\(RemoteMessageContentMarkup.attribute)]")
    else {
      return html
    }
    for element in elements {
      guard
        let identifier = try? element.attr(RemoteMessageContentMarkup.attribute),
        let image = imagesByIdentifier[identifier]
      else {
        continue
      }
      _ = try? element.attr(
        "src",
        "data:\(image.mimeType);base64,\(image.data.base64EncodedString())"
      )
      _ = try? element.removeAttr(RemoteMessageContentMarkup.attribute)
    }
    guard let resolvedHTML = try? document.outerHtml() else {
      return html
    }
    let loadedIdentifiers = Set(imagesByIdentifier.keys)
    return SanitizedMessageHTML(
      documentHTML: resolvedHTML,
      remoteImageReferences: html.remoteImageReferences.filter {
        !loadedIdentifiers.contains($0.identifier)
      }
    )
  }
}

enum RemoteMessageContentPolicy {
  static func requestEquivalentURL(_ url: URL) -> URL {
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.fragment = nil
    let normalizedHost = components?.host?.lowercased()
    components?.host = normalizedHost
    if (components?.scheme?.lowercased() == "https" && components?.port == 443)
      || (components?.scheme?.lowercased() == "http" && components?.port == 80)
    {
      components?.port = nil
    }
    return components?.url ?? url
  }

  static func isLoadableHTTPSURL(_ url: URL?) -> Bool {
    url?.scheme?.lowercased() == "https"
      && url?.host != nil
      && url?.user == nil
      && url?.password == nil
  }
}

enum RemoteMessageContentError: Error {
  case responseTooLarge
}

enum RemoteMessageContentRedirectPolicy {
  static func redirectedRequest(_ request: URLRequest) -> URLRequest? {
    guard RemoteMessageContentPolicy.isLoadableHTTPSURL(request.url) else {
      return nil
    }
    return isolatedRequest(request)
  }

  static func isolatedRequest(_ request: URLRequest) -> URLRequest {
    var isolatedRequest = request
    isolatedRequest.httpShouldHandleCookies = false
    for field in ["Authorization", "Cookie", "Referer"] {
      isolatedRequest.setValue(nil, forHTTPHeaderField: field)
    }
    return isolatedRequest
  }
}

class RemoteMessageContentRedirectDelegate: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _: URLSession,
    task _: URLSessionTask,
    willPerformHTTPRedirection _: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(RemoteMessageContentRedirectPolicy.redirectedRequest(request))
  }

  func urlSession(
    _: URLSession,
    task _: URLSessionTask,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
      completionHandler(.performDefaultHandling, nil)
    } else {
      completionHandler(.cancelAuthenticationChallenge, nil)
    }
  }
}

enum RemoteMessageContentSession {
  static func makeConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    configuration.urlCredentialStorage = nil
    configuration.timeoutIntervalForResource = 30
    return configuration
  }

  static func data(
    for request: URLRequest,
    maximumByteCount: Int,
    configuration: URLSessionConfiguration
  ) async throws -> (Data, URLResponse) {
    try await RemoteMessageContentDataDelegate(maximumByteCount: maximumByteCount).load(
      request,
      configuration: configuration
    )
  }
}

private struct RemoteMessageContentAdmission {
  let image: RemoteMessageImage
  let pixelCount: Int
}

struct RemoteMessageContentLoader {
  typealias Fetch = (URLRequest, Int) async throws -> (Data, URLResponse)

  private let fetch: Fetch?
  private let maximumLoadDuration: TimeInterval
  private let maximumTotalByteCount: Int
  private let maximumTotalPixelCount: Int
  private let now: () -> Date

  init(
    maximumLoadDuration: TimeInterval = 30,
    maximumTotalByteCount: Int = MailboxMessageImagePolicy.maximumTotalByteCount,
    maximumTotalPixelCount: Int = MailboxMessageImagePolicy.maximumTotalPixelCount,
    now: @escaping () -> Date = Date.init,
    fetch: Fetch? = nil
  ) {
    self.fetch = fetch
    self.maximumLoadDuration = maximumLoadDuration
    self.maximumTotalByteCount = maximumTotalByteCount
    self.maximumTotalPixelCount = maximumTotalPixelCount
    self.now = now
  }

  func load(_ html: SanitizedMessageHTML) async throws -> RemoteMessageContentLoadResult {
    let deadline = now().addingTimeInterval(maximumLoadDuration)
    let sessionConfiguration = fetch == nil ? RemoteMessageContentSession.makeConfiguration() : nil
    var images: [RemoteMessageImage] = []
    var attemptedIdentifiers = Set<String>()
    var attemptedImageCount = 0
    var loadedByteCount = 0
    var loadedPixelCount = 0
    let occurrenceCounts = RemoteMessageContentMarkup.occurrenceCounts(in: html)
    for reference in html.remoteImageReferences {
      try Task.checkCancellation()
      guard RemoteMessageContentPolicy.isLoadableHTTPSURL(reference.url) else {
        continue
      }
      guard let occurrenceCount = occurrenceCounts[reference.identifier], occurrenceCount > 0 else {
        continue
      }
      let remainingLoadDuration = deadline.timeIntervalSince(now())
      guard remainingLoadDuration > 0 else { break }
      guard attemptedImageCount < MailboxMessageImagePolicy.maximumImageAttemptCount else {
        break
      }
      attemptedImageCount += 1
      attemptedIdentifiers.insert(reference.identifier)
      guard
        let admission = try await admission(
          for: reference,
          remainingLoadDuration: remainingLoadDuration,
          remainingByteCount: (maximumTotalByteCount - loadedByteCount) / occurrenceCount,
          remainingPixelCount: (maximumTotalPixelCount - loadedPixelCount) / occurrenceCount,
          sessionConfiguration: sessionConfiguration
        )
      else {
        continue
      }
      images.append(admission.image)
      loadedByteCount += admission.image.data.count * occurrenceCount
      loadedPixelCount += admission.pixelCount * occurrenceCount
    }
    return RemoteMessageContentLoadResult(
      failedImageCount: html.remoteImageReferences.count - images.count,
      html: RemoteMessageImageResolver.resolve(html, images: images)
        .prioritizingUnattemptedRemoteImages(attemptedIdentifiers),
      loadedByteCount: loadedByteCount,
      loadedImageCount: images.count,
      loadedPixelCount: loadedPixelCount
    )
  }

  private func admission(
    for reference: RemoteMessageImageReference,
    remainingLoadDuration: TimeInterval,
    remainingByteCount: Int,
    remainingPixelCount: Int,
    sessionConfiguration: URLSessionConfiguration?
  ) async throws -> RemoteMessageContentAdmission? {
    guard RemoteMessageContentPolicy.isLoadableHTTPSURL(reference.url) else {
      return nil
    }
    let maximumByteCount = min(
      MailboxMessageImagePolicy.maximumImageByteCount,
      remainingByteCount
    )
    guard maximumByteCount > 0, remainingPixelCount > 0 else { return nil }
    do {
      let (data, response) = try await response(
        for: request(url: reference.url, timeoutInterval: remainingLoadDuration),
        maximumByteCount: maximumByteCount,
        sessionConfiguration: sessionConfiguration
      )
      return admittedImage(
        reference: reference,
        data: data,
        response: response,
        remainingByteCount: remainingByteCount,
        remainingPixelCount: remainingPixelCount
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      if Task.isCancelled {
        throw CancellationError()
      }
      return nil
    }
  }

  private func response(
    for request: URLRequest,
    maximumByteCount: Int,
    sessionConfiguration: URLSessionConfiguration?
  ) async throws -> (Data, URLResponse) {
    if let fetch {
      return try await fetch(request, maximumByteCount)
    }
    guard let sessionConfiguration else { throw CancellationError() }
    sessionConfiguration.timeoutIntervalForResource = request.timeoutInterval
    return try await RemoteMessageContentSession.data(
      for: request,
      maximumByteCount: maximumByteCount,
      configuration: sessionConfiguration
    )
  }

  private func admittedImage(
    reference: RemoteMessageImageReference,
    data: Data,
    response: URLResponse,
    remainingByteCount: Int,
    remainingPixelCount: Int
  ) -> RemoteMessageContentAdmission? {
    guard let httpResponse = response as? HTTPURLResponse,
      (200..<300).contains(httpResponse.statusCode),
      RemoteMessageContentPolicy.isLoadableHTTPSURL(httpResponse.url),
      let mimeType = MailboxMessageImagePolicy.normalizedSupportedMIMEType(
        httpResponse.mimeType
      ),
      let pixelCount = MailboxMessageImagePolicy.admittedPixelCount(
        data,
        mimeType: mimeType,
        remainingByteCount: remainingByteCount,
        remainingPixelCount: remainingPixelCount
      )
    else {
      return nil
    }
    return RemoteMessageContentAdmission(
      image: RemoteMessageImage(
        data: data,
        identifier: reference.identifier,
        mimeType: mimeType
      ),
      pixelCount: pixelCount
    )
  }
}
