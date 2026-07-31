import Foundation
import Observation
import SwiftSoup

enum MessageHTMLHiddenStylePatterns {
  static let preClean =
    #"(?:^|;)\s*(?:visibility\s*:\s*(?:hidden|collapse)|"#
    + #"opacity\s*:\s*(?:\+?(?:0+(?:\.0*)?|\.0+)|-(?:\d+(?:\.\d*)?|\.\d+))(?:%)?)"#
    + #"(?:\s*!important)?\s*(?:;|$)"#

  static let readable =
    #"(?:^|;)\s*(?:display\s*:\s*none|"#
    + #"(?:font-size|height|width|line-height)\s*:\s*(?:0+(?:\.0*)?|\.0+)"#
    + #"(?:[a-z%]+)?|(?:text-indent|margin-(?:left|right|top))\s*:\s*-"#
    + #"(?:[1-9]\d*(?:\.\d+)?|0*\.\d*[1-9]\d*)(?:[a-z%]+)?|"#
    + #"margin\s*:\s*[^;]*-(?:[1-9]\d*(?:\.\d+)?|"#
    + #"0*\.\d*[1-9]\d*)(?:[a-z%]+)?[^;]*)"#
    + #"(?:\s*!important)?\s*(?:;|$)"#

  static let presentation =
    #"(?:^|;)\s*(?:display\s*:\s*none|"#
    + #"(?:height|width)\s*:\s*(?:0+(?:\.0*)?|\.0+)"#
    + #"(?:[a-z%]+)?)"#
    + #"(?:\s*!important)?\s*(?:;|$)"#
}

extension MessageHTMLSanitizer {
  static func sourceContent(in document: Document) throws -> (
    hasText: Bool,
    hasExplicitlyHiddenText: Bool
  ) {
    let hasText = try hasReadableText(document.text())
    let hasExplicitlyHiddenText = try document.select("[hidden], [style]").contains { element in
      let elementHasText = try hasReadableText(element.text())
      let style = try element.attr("style")
      return elementHasText
        && (element.hasAttr("hidden")
          || style.range(
            of: MessageHTMLHiddenStylePatterns.preClean,
            options: [.regularExpression, .caseInsensitive]
          ) != nil
          || style.range(
            of: MessageHTMLHiddenStylePatterns.readable,
            options: [.regularExpression, .caseInsensitive]
          ) != nil)
    }
    return (hasText, hasExplicitlyHiddenText)
  }

  static func hasReadableText(_ text: String) -> Bool {
    let ignoredReadableScalars =
      CharacterSet.whitespacesAndNewlines
      .union(.controlCharacters)
      .union(.nonBaseCharacters)
    return text.unicodeScalars.contains { scalar in
      !ignoredReadableScalars.contains(scalar)
        && scalar.properties.generalCategory != .format
    }
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
    let action: (exceedsLimit: Bool, task: URLSessionDataTask?) = lock.withLock {
      guard data.count <= maximumByteCount - chunk.count else {
        return (true, self.task)
      }
      data.append(chunk)
      return (false, nil)
    }
    if action.exceedsLimit {
      action.task?.cancel()
      finish(
        .failure(
          RemoteMessageContentError.responseTooLarge(
            receivedByteCount: maximumByteCount
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
