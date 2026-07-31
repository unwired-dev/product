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
      finish(.failure(RemoteMessageContentError.responseTooLarge))
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
      finish(.failure(RemoteMessageContentError.responseTooLarge))
    }
  }

  func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
    let state: (isCancelled: Bool, result: (Data, URLResponse)?) = lock.withLock {
      (isCancelled, response.map { (data, $0) })
    }
    if let error {
      finish(.failure(state.isCancelled ? CancellationError() : error))
    } else if let result = state.result {
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
