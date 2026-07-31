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
      try element.removeAttr("src")
      guard !MessageHTMLSanitizer.hasZeroDimension(element) else {
        continue
      }
      let reference: RemoteMessageImageReference
      if let existingReference = referencesByURL[url] {
        reference = existingReference
      } else {
        reference = RemoteMessageImageReference(
          identifier: "remote-image-\(references.count)",
          url: url
        )
        references.append(reference)
        referencesByURL[url] = reference
      }
      try element.attr(attribute, reference.identifier)
    }
    return references
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
  static func isLoadableHTTPSURL(_ url: URL?) -> Bool {
    url?.scheme?.lowercased() == "https"
      && url?.host != nil
      && url?.user == nil
      && url?.password == nil
  }
}

private enum RemoteMessageContentError: Error {
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

private final class RemoteMessageContentRedirectDelegate: NSObject, URLSessionTaskDelegate {
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
    return configuration
  }

  static func data(
    for request: URLRequest,
    maximumByteCount: Int,
    session: URLSession
  ) async throws -> (Data, URLResponse) {
    let delegate = RemoteMessageContentRedirectDelegate()
    let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
    guard
      response.expectedContentLength <= Int64(maximumByteCount)
        || response.expectedContentLength == NSURLSessionTransferSizeUnknown
    else {
      throw RemoteMessageContentError.responseTooLarge
    }
    var data = Data()
    if response.expectedContentLength > 0 {
      data.reserveCapacity(Int(response.expectedContentLength))
    }
    for try await byte in bytes {
      guard data.count < maximumByteCount else {
        throw RemoteMessageContentError.responseTooLarge
      }
      data.append(byte)
    }
    try Task.checkCancellation()
    return (data, response)
  }
}

struct RemoteMessageContentLoadResult: Equatable, Sendable {
  let failedImageCount: Int
  let html: SanitizedMessageHTML
  let loadedImageCount: Int
}

private struct RemoteMessageContentAdmission {
  let image: RemoteMessageImage
  let pixelCount: Int
}

struct RemoteMessageContentLoader {
  typealias Fetch = (URLRequest, Int) async throws -> (Data, URLResponse)

  private let fetch: Fetch?

  init() {
    fetch = nil
  }

  init(fetch: @escaping Fetch) {
    self.fetch = fetch
  }

  func load(_ html: SanitizedMessageHTML) async throws -> RemoteMessageContentLoadResult {
    let session =
      fetch == nil
      ? URLSession(configuration: RemoteMessageContentSession.makeConfiguration())
      : nil
    defer { session?.finishTasksAndInvalidate() }
    var images: [RemoteMessageImage] = []
    var attemptedImageCount = 0
    var loadedByteCount = 0
    var loadedPixelCount = 0
    for reference in html.remoteImageReferences {
      try Task.checkCancellation()
      guard RemoteMessageContentPolicy.isLoadableHTTPSURL(reference.url) else {
        continue
      }
      guard attemptedImageCount < MailboxMessageImagePolicy.maximumImageAttemptCount else {
        break
      }
      attemptedImageCount += 1
      guard
        let admission = try await admission(
          for: reference,
          remainingByteCount: MailboxMessageImagePolicy.maximumTotalByteCount - loadedByteCount,
          remainingPixelCount: MailboxMessageImagePolicy.maximumTotalPixelCount - loadedPixelCount,
          session: session
        )
      else {
        continue
      }
      images.append(admission.image)
      loadedByteCount += admission.image.data.count
      loadedPixelCount += admission.pixelCount
    }
    return RemoteMessageContentLoadResult(
      failedImageCount: html.remoteImageReferences.count - images.count,
      html: RemoteMessageImageResolver.resolve(html, images: images),
      loadedImageCount: images.count
    )
  }

  private func admission(
    for reference: RemoteMessageImageReference,
    remainingByteCount: Int,
    remainingPixelCount: Int,
    session: URLSession?
  ) async throws -> RemoteMessageContentAdmission? {
    guard RemoteMessageContentPolicy.isLoadableHTTPSURL(reference.url) else {
      return nil
    }
    let maximumByteCount = min(
      MailboxMessageImagePolicy.maximumImageByteCount,
      remainingByteCount
    )
    guard maximumByteCount > 0 else { return nil }
    do {
      let (data, response) = try await response(
        for: request(url: reference.url),
        maximumByteCount: maximumByteCount,
        session: session
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
    session: URLSession?
  ) async throws -> (Data, URLResponse) {
    if let fetch {
      return try await fetch(request, maximumByteCount)
    }
    guard let session else {
      throw CancellationError()
    }
    return try await RemoteMessageContentSession.data(
      for: request,
      maximumByteCount: maximumByteCount,
      session: session
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

  private func request(url: URL) -> URLRequest {
    var request = URLRequest(
      url: url,
      cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: 30
    )
    request.httpMethod = "GET"
    request.setValue(
      "image/png,image/jpeg,image/gif,image/webp",
      forHTTPHeaderField: "Accept"
    )
    return RemoteMessageContentRedirectPolicy.isolatedRequest(request)
  }
}
