import Foundation
import Observation
import SwiftSoup

enum MessageHTMLHiddenStylePatterns {
  static func isPreCleanHidden(_ declarations: [StyleDeclaration]) -> Bool {
    if ["hidden", "collapse"].contains(
      effectiveValue("visibility", in: declarations, where: isVisibilityValue)
    ) {
      return true
    }
    guard let opacity = effectiveValue("opacity", in: declarations, where: isOpacityValue) else {
      return false
    }
    if let calculatedOpacity = simpleCalculatedOpacity(opacity) { return calculatedOpacity <= 0 }
    return opacity.range(
      of: #"^(?:\+?(?:0+(?:\.0*)?|\.0+)|-(?:\d+(?:\.\d*)?|\.\d+))(?:%)?$"#,
      options: .regularExpression
    ) != nil
  }

  static func isPresentationHidden(
    _ declarations: [StyleDeclaration],
    in element: Element? = nil
  ) -> Bool {
    if effectiveValue("display", in: declarations, where: isDisplayValue) == "none" {
      return true
    }
    if ["height", "width"].contains(where: { property in
      effectiveValue(property, in: declarations) { value in
        isLengthValue(value, for: property)
      }.map(isZeroLengthValue) == true
    }) {
      return true
    }
    guard element.map(maximumDimensionsApply) != false else { return false }
    return [("max-width", "min-width"), ("max-height", "min-height")].contains { properties in
      let (maximumProperty, minimumProperty) = properties
      guard
        effectiveValue(
          maximumProperty, in: declarations,
          where: {
            isLengthValue($0, for: maximumProperty)
          }
        ).map(isZeroLengthValue) == true
      else { return false }
      let minimum = effectiveValue(
        minimumProperty, in: declarations,
        where: {
          isLengthValue($0, for: minimumProperty)
        })
      return minimum.map(isPositiveLengthValue) != true
    }
  }

  private static func maximumDimensionsApply(to element: Element) -> Bool {
    if let display = InlineImageDimensionPolicy.value("display", in: element)?.lowercased() {
      let components = display.split(whereSeparator: \Character.isWhitespace).map(String.init)
      if display == "contents" || components == ["inline"]
        || Set(components) == Set(["inline", "flow"])
      {
        return false
      }
      return true
    }
    return ![
      "a", "b", "cite", "code", "em", "i", "q", "s", "small", "span", "strike",
      "strong", "sub", "sup", "u",
    ].contains(element.tagName().lowercased())
  }

  private static func isPositiveLengthValue(_ value: String) -> Bool {
    if let pixels = CSSLengthValuePolicy.absolutePixelLengthValue(value) { return pixels > 0 }
    if let pixels = simpleCalculatedPixelLengthValue(value) { return pixels > 0 }
    let numericPrefix = value.prefix { "0123456789+.".contains($0) }
    return Double(numericPrefix).map { $0 > 0 } == true
  }
}

enum RemoteMessageContentPolicy {
  static func requestEquivalentURL(_ url: URL) -> URL {
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.fragment = nil
    components?.scheme = url.scheme?.lowercased()
    let normalizedHost = components?.host?.lowercased()
    components?.host = normalizedHost
    if components?.path.isEmpty == true { components?.path = "/" }
    if (components?.scheme?.lowercased() == "https" && components?.port == 443)
      || (components?.scheme?.lowercased() == "http" && components?.port == 80)
    {
      components?.port = nil
    }
    let equivalentURL = components?.url ?? url
    let percentNormalizedURL =
      URL(string: normalizedPercentEscapes(equivalentURL.absoluteString)) ?? equivalentURL
    return percentNormalizedURL.standardized
  }

  private static func normalizedPercentEscapes(_ value: String) -> String {
    var normalized = ""
    var index = value.startIndex
    while index < value.endIndex {
      guard value[index] == "%" else {
        normalized.append(value[index])
        index = value.index(after: index)
        continue
      }

      let firstDigit = value.index(after: index)
      guard firstDigit < value.endIndex else {
        normalized.append(value[index])
        break
      }
      let secondDigit = value.index(after: firstDigit)
      guard secondDigit < value.endIndex else {
        normalized.append(contentsOf: value[index...])
        break
      }

      let digits = String(value[firstDigit...secondDigit])
      if let byte = UInt8(digits, radix: 16), isUnreservedURLByte(byte) {
        normalized.unicodeScalars.append(UnicodeScalar(byte))
      } else {
        normalized.append("%")
        normalized.append(contentsOf: digits.uppercased())
      }
      index = value.index(after: secondDigit)
    }
    return normalized
  }

  private static func isUnreservedURLByte(_ byte: UInt8) -> Bool {
    (byte >= 0x41 && byte <= 0x5A)
      || (byte >= 0x61 && byte <= 0x7A)
      || (byte >= 0x30 && byte <= 0x39)
      || [0x2D, 0x2E, 0x5F, 0x7E].contains(byte)
  }

  static func isLoadableHTTPSURL(_ url: URL?) -> Bool {
    url?.scheme?.lowercased() == "https"
      && url?.host != nil
      && url?.user == nil
      && url?.password == nil
  }
}

enum RemoteMessageContentError: Error {
  case responseTooLarge(receivedByteCount: Int)
  case transferFailed(receivedByteCount: Int)
}

final class RemoteMessageContentDataDelegate: RemoteMessageContentRedirectDelegate,
  URLSessionDataDelegate, @unchecked Sendable
{
  private let lock = NSLock()
  private let maximumByteCount: Int
  private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
  private var data = Data()
  private var isCancelled = false
  private var response: URLResponse?
  private var session: URLSession?
  private var task: URLSessionDataTask?

  init(maximumByteCount: Int) {
    self.maximumByteCount = maximumByteCount
  }

  func load(
    _ request: URLRequest,
    configuration: URLSessionConfiguration
  ) async throws -> (Data, URLResponse) {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        lock.withLock {
          guard !isCancelled else {
            continuation.resume(throwing: CancellationError())
            return
          }
          self.continuation = continuation
          let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
          let task = session.dataTask(with: request)
          self.session = session
          self.task = task
          task.resume()
        }
      }
    } onCancel: {
      cancel()
    }
  }

  func cancel() {
    let task = lock.withLock {
      isCancelled = true
      return self.task
    }
    task?.cancel()
  }

  func urlSession(
    _: URLSession,
    dataTask _: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard
      response.expectedContentLength <= Int64(maximumByteCount)
        || response.expectedContentLength == NSURLSessionTransferSizeUnknown
    else {
      completionHandler(.cancel)
      finish(
        .failure(RemoteMessageContentError.responseTooLarge(receivedByteCount: 0))
      )
      return
    }
    lock.withLock { self.response = response }
    completionHandler(.allow)
  }

  func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive chunk: Data) {
    let action: (receivedByteCount: Int?, task: URLSessionDataTask?) = lock.withLock {
      let (receivedByteCount, overflow) = data.count.addingReportingOverflow(chunk.count)
      guard !overflow, receivedByteCount <= maximumByteCount else {
        return (overflow ? Int.max : receivedByteCount, self.task)
      }
      data.append(chunk)
      return (nil, nil)
    }
    if let receivedByteCount = action.receivedByteCount {
      action.task?.cancel()
      finish(
        .failure(
          RemoteMessageContentError.responseTooLarge(
            receivedByteCount: receivedByteCount
          )
        )
      )
    }
  }

  func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
    let state:
      (
        isCancelled: Bool,
        transfer: (receivedByteCount: Int, result: (Data, URLResponse)?)
      ) =
        lock.withLock {
          let receivedByteCount = self.data.endIndex - self.data.startIndex
          return (isCancelled, (receivedByteCount, response.map { (self.data, $0) }))
        }
    if error != nil {
      let completionError: Error =
        if state.isCancelled {
          CancellationError()
        } else {
          RemoteMessageContentError.transferFailed(
            receivedByteCount: state.transfer.receivedByteCount
          )
        }
      finish(.failure(completionError))
    } else if let result = state.transfer.result {
      finish(.success(result))
    } else {
      finish(.failure(URLError(.badServerResponse)))
    }
  }

  private func finish(_ result: Result<(Data, URLResponse), Error>) {
    let completion = lock.withLock {
      () -> (
        CheckedContinuation<(Data, URLResponse), Error>?,
        URLSession?
      ) in
      let completion = (continuation, session)
      continuation = nil
      session = nil
      task = nil
      return completion
    }
    completion.1?.finishTasksAndInvalidate()
    completion.0?.resume(with: result)
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
    state = .loading
    loadRequest = UUID()
  }

  func load(
    originalHTML: SanitizedMessageHTML,
    using loader: (SanitizedMessageHTML) async throws -> RemoteMessageContentLoadResult
  ) async {
    guard loadRequest != nil, state == .loading else { return }
    let requestedHTML = loadedHTML ?? originalHTML
    do {
      let result = try await loader(requestedHTML)
      try Task.checkCancellation()
      loadedHTML = result.html
      state =
        result.failedImageCount == 0
        ? .blocked
        : .failed(result.failedImageCount)
    } catch is CancellationError {
    } catch {
      state = .failed(requestedHTML.remoteImageReferences.count)
    }
  }

  func reset() {
    loadRequest = nil
    loadedHTML = nil
    state = .blocked
  }
}

extension SanitizedMessageHTML {
  func prioritizingUnattemptedRemoteImages(_ attemptedIdentifiers: Set<String>) -> Self {
    let unattempted = remoteImageReferences.filter {
      !attemptedIdentifiers.contains($0.identifier)
    }
    let attempted = remoteImageReferences.filter {
      attemptedIdentifiers.contains($0.identifier)
    }
    return Self(documentHTML: documentHTML, remoteImageReferences: unattempted + attempted)
  }
}

extension RemoteMessageContentLoader {
  func request(url: URL, timeoutInterval: TimeInterval) -> URLRequest {
    var request = URLRequest(
      url: url,
      cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: min(30, timeoutInterval)
    )
    request.httpMethod = "GET"
    request.setValue(
      "image/png,image/jpeg,image/gif,image/webp",
      forHTTPHeaderField: "Accept"
    )
    return RemoteMessageContentRedirectPolicy.isolatedRequest(request)
  }
}
