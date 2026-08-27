import Foundation
import SwiftSoup

// swiftlint:disable file_length

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
        scheme == "https",
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
    let onePixelPattern = #"^\+?0*1(?:\.0*)?(?:px)?$"#
    return ["width", "height"].allSatisfy { dimension in
      let value = ((try? element.attr(dimension)) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if InlineImageDimensionPolicy.hasExpandingMinimum(dimension, in: element) {
        return false
      }
      if InlineImageDimensionPolicy.hasOnePixelUsedDimension(dimension, in: element) { return true }
      if [dimension, "max-\(dimension)"].contains(where: { property in
        InlineImageDimensionPolicy.value(property, in: element).map {
          InlineImageDimensionPolicy.isOnePixel($0, dimension: dimension, in: element)
        } == true
      }) {
        return true
      }
      let hasStyleOverride =
        InlineImageDimensionPolicy.value(dimension, in: element) != nil
      return
        !hasStyleOverride
        && value.range(of: onePixelPattern, options: [.regularExpression, .caseInsensitive]) != nil
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
      linkPresentations: html.linkPresentations,
      remoteImageReferences: html.remoteImageReferences.filter {
        !loadedIdentifiers.contains($0.identifier)
      }
    )
  }
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
  private static let maximumRedirectCount = 3
  private let redirectLock = NSLock()
  private var redirectCount = 0

  func urlSession(
    _: URLSession,
    task _: URLSessionTask,
    willPerformHTTPRedirection _: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    let permitsRedirect = redirectLock.withLock {
      guard redirectCount < Self.maximumRedirectCount else { return false }
      redirectCount += 1
      return true
    }
    completionHandler(
      permitsRedirect
        ? RemoteMessageContentRedirectPolicy.redirectedRequest(request)
        : nil
    )
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

// swiftlint:disable:next type_body_length
struct RemoteMessageContentLoader {
  typealias Fetch = (URLRequest, Int) async throws -> (Data, URLResponse)

  private let cache: AuthorizedRemoteContentCache
  private let cacheContext: AuthorizedRemoteContentCacheContext?
  private let fetch: Fetch?
  private let maximumConcurrentRequestCount: Int
  private let maximumLoadDuration: TimeInterval
  private let maximumTotalByteCount: Int
  private let maximumTotalPixelCount: Int
  private let messageId: StableProviderMessageIdentity?
  private let monotonicTime: () -> TimeInterval
  private let requestGate: ProductAccountRemoteImageRequestGate?

  init(
    cache: AuthorizedRemoteContentCache = AuthorizedRemoteContentCache(),
    cacheContext: AuthorizedRemoteContentCacheContext? = nil,
    maximumConcurrentRequestCount: Int = 1,
    maximumLoadDuration: TimeInterval = 30,
    maximumTotalByteCount: Int = MailboxMessageImagePolicy.maximumTotalByteCount,
    maximumTotalPixelCount: Int = MailboxMessageImagePolicy.maximumTotalPixelCount,
    messageId: StableProviderMessageIdentity? = nil,
    monotonicTime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    requestGate: ProductAccountRemoteImageRequestGate? = nil,
    fetch: Fetch? = nil
  ) {
    self.cache = cache
    self.cacheContext = cacheContext
    self.fetch = fetch
    self.maximumConcurrentRequestCount = max(1, maximumConcurrentRequestCount)
    self.maximumLoadDuration = maximumLoadDuration
    self.maximumTotalByteCount = maximumTotalByteCount
    self.maximumTotalPixelCount = maximumTotalPixelCount
    self.messageId = messageId
    self.monotonicTime = monotonicTime
    self.requestGate = requestGate
  }

  func load(_ html: SanitizedMessageHTML) async throws -> RemoteMessageContentLoadResult {
    guard maximumConcurrentRequestCount > 1 else {
      return try await loadSerially(html)
    }
    return try await loadConcurrently(html)
  }

  private func loadSerially(
    _ html: SanitizedMessageHTML
  ) async throws -> RemoteMessageContentLoadResult {
    let deadline = monotonicTime() + maximumLoadDuration
    var progress = RemoteMessageContentLoadProgress()
    let occurrenceCounts = RemoteMessageContentMarkup.occurrenceCounts(in: html)
    for reference in html.remoteImageReferences {
      try Task.checkCancellation()
      guard RemoteMessageContentPolicy.isLoadableHTTPSURL(reference.url) else {
        continue
      }
      guard let occurrenceCount = occurrenceCounts[reference.identifier], occurrenceCount > 0 else {
        continue
      }
      let remainingLoadDuration = deadline - monotonicTime()
      guard remainingLoadDuration > 0,
        progress.attemptedImageCount < MailboxMessageImagePolicy.maximumImageAttemptCount
      else {
        break
      }
      let maximumResponseByteCount = min(
        (maximumTotalByteCount - progress.loadedByteCount) / occurrenceCount,
        maximumTotalByteCount - progress.receivedByteCount
      )
      let remainingPixelCount =
        (maximumTotalPixelCount - progress.loadedPixelCount) / occurrenceCount
      guard maximumResponseByteCount > 0, remainingPixelCount > 0 else { continue }
      progress.attemptedImageCount += 1
      progress.attemptedIdentifiers.insert(reference.identifier)
      guard
        let attempt = try await admission(
          for: reference,
          deadline: deadline,
          remainingLoadDuration: remainingLoadDuration,
          maximumByteCount: maximumResponseByteCount,
          remainingPixelCount: remainingPixelCount
        )
      else {
        continue
      }
      progress.receivedByteCount += attempt.receivedByteCount
      guard let admission = attempt.admission else { continue }
      if let cachedKey = attempt.cachedKey {
        progress.cachedKeys.insert(cachedKey)
      }
      progress.images.append(admission.image)
      progress.loadedByteCount += admission.image.data.count * occurrenceCount
      progress.loadedPixelCount += admission.pixelCount * occurrenceCount
    }
    return progress.loadResult(for: html)
  }

  private struct ConcurrentCandidate: Sendable {
    let maximumByteCount: Int
    let maximumPixelCount: Int
    let occurrenceCount: Int
    let order: Int
    let reference: RemoteMessageImageReference
  }

  private struct ConcurrentAttempt: Sendable {
    let admission: RemoteMessageContentAdmission?
    let cachedKey: AuthorizedRemoteContentCacheKey?
    let candidate: ConcurrentCandidate
    let receivedByteCount: Int
  }

  private struct AdmissionAttempt: Sendable {
    let admission: RemoteMessageContentAdmission?
    let cachedKey: AuthorizedRemoteContentCacheKey?
    let receivedByteCount: Int
  }

  // swiftlint:disable:next function_body_length
  private func loadConcurrently(
    _ html: SanitizedMessageHTML
  ) async throws -> RemoteMessageContentLoadResult {
    let deadline = monotonicTime() + maximumLoadDuration
    let occurrenceCounts = RemoteMessageContentMarkup.occurrenceCounts(in: html)
    var nextReferenceIndex = 0
    var progress = RemoteMessageContentLoadProgress()

    while nextReferenceIndex < html.remoteImageReferences.count,
      progress.attemptedImageCount < MailboxMessageImagePolicy.maximumImageAttemptCount
    {
      try Task.checkCancellation()
      let remainingLoadDuration = deadline - monotonicTime()
      guard remainingLoadDuration > 0 else { break }
      let candidates = concurrentCandidates(
        html.remoteImageReferences,
        nextReferenceIndex: &nextReferenceIndex,
        occurrenceCounts: occurrenceCounts,
        progress: progress
      )
      guard !candidates.isEmpty else { continue }
      progress.attemptedImageCount += candidates.count
      progress.attemptedIdentifiers.formUnion(candidates.map(\.reference.identifier))

      let attempts = try await withThrowingTaskGroup(of: ConcurrentAttempt.self) { group in
        for candidate in candidates {
          group.addTask {
            let attempt = try await admission(
              for: candidate.reference,
              deadline: deadline,
              remainingLoadDuration: remainingLoadDuration,
              maximumByteCount: candidate.maximumByteCount,
              remainingPixelCount: candidate.maximumPixelCount
            )
            return ConcurrentAttempt(
              admission: attempt?.admission,
              cachedKey: attempt?.cachedKey,
              candidate: candidate,
              receivedByteCount: attempt?.receivedByteCount ?? 0
            )
          }
        }
        var attempts: [ConcurrentAttempt] = []
        for try await attempt in group {
          attempts.append(attempt)
        }
        return attempts.sorted { $0.candidate.order < $1.candidate.order }
      }

      for concurrentAttempt in attempts {
        progress.receivedByteCount += concurrentAttempt.receivedByteCount
        guard let admission = concurrentAttempt.admission else { continue }
        if let cachedKey = concurrentAttempt.cachedKey {
          progress.cachedKeys.insert(cachedKey)
        }
        let occurrenceCount = concurrentAttempt.candidate.occurrenceCount
        progress.images.append(admission.image)
        progress.loadedByteCount += admission.image.data.count * occurrenceCount
        progress.loadedPixelCount += admission.pixelCount * occurrenceCount
      }
    }

    return RemoteMessageContentLoadResult(
      cachedKeys: progress.cachedKeys,
      failedImageCount: html.remoteImageReferences.count - progress.images.count,
      html: RemoteMessageImageResolver.resolve(html, images: progress.images)
        .prioritizingUnattemptedRemoteImages(progress.attemptedIdentifiers),
      loadedByteCount: progress.loadedByteCount,
      loadedImageCount: progress.images.count,
      loadedPixelCount: progress.loadedPixelCount
    )
  }

  private func concurrentCandidates(
    _ references: [RemoteMessageImageReference],
    nextReferenceIndex: inout Int,
    occurrenceCounts: [String: Int],
    progress: RemoteMessageContentLoadProgress
  ) -> [ConcurrentCandidate] {
    var remainingReceivedByteCount = maximumTotalByteCount - progress.receivedByteCount
    var remainingLoadedByteCount = maximumTotalByteCount - progress.loadedByteCount
    var remainingPixelCount = maximumTotalPixelCount - progress.loadedPixelCount
    var candidates: [ConcurrentCandidate] = []
    while nextReferenceIndex < references.count,
      candidates.count < maximumConcurrentRequestCount,
      progress.attemptedImageCount + candidates.count
        < MailboxMessageImagePolicy.maximumImageAttemptCount
    {
      let order = nextReferenceIndex
      let reference = references[nextReferenceIndex]
      guard RemoteMessageContentPolicy.isLoadableHTTPSURL(reference.url),
        let occurrenceCount = occurrenceCounts[reference.identifier], occurrenceCount > 0
      else {
        nextReferenceIndex += 1
        continue
      }
      let maximumByteCount = min(
        MailboxMessageImagePolicy.maximumImageByteCount,
        remainingReceivedByteCount,
        remainingLoadedByteCount / occurrenceCount
      )
      let maximumPixelCount = min(
        MailboxMessageImagePolicy.maximumImagePixelCount,
        remainingPixelCount / occurrenceCount
      )
      guard maximumByteCount > 0, maximumPixelCount > 0 else { break }
      nextReferenceIndex += 1
      candidates.append(
        ConcurrentCandidate(
          maximumByteCount: maximumByteCount,
          maximumPixelCount: maximumPixelCount,
          occurrenceCount: occurrenceCount,
          order: order,
          reference: reference
        ))
      remainingReceivedByteCount -= maximumByteCount
      remainingLoadedByteCount -= maximumByteCount * occurrenceCount
      remainingPixelCount -= maximumPixelCount * occurrenceCount
    }
    return candidates
  }

  // swiftlint:disable:next function_body_length
  private func admission(
    for reference: RemoteMessageImageReference,
    deadline: TimeInterval,
    remainingLoadDuration: TimeInterval,
    maximumByteCount: Int,
    remainingPixelCount: Int
  ) async throws -> AdmissionAttempt? {
    guard RemoteMessageContentPolicy.isLoadableHTTPSURL(reference.url) else {
      return nil
    }
    let maximumByteCount = min(MailboxMessageImagePolicy.maximumImageByteCount, maximumByteCount)
    guard maximumByteCount > 0, remainingPixelCount > 0 else { return nil }
    let cacheKey = cacheContext?.key(for: reference)
    if let cacheKey,
      let cachedImage = cache.image(for: cacheKey, identifier: reference.identifier)
    {
      if let admission = admittedImage(
        reference: reference,
        data: cachedImage.data,
        mimeType: cachedImage.mimeType,
        remainingByteCount: maximumByteCount,
        remainingPixelCount: remainingPixelCount
      ) {
        return AdmissionAttempt(admission: admission, cachedKey: cacheKey, receivedByteCount: 0)
      }
      cache.remove(cacheKey)
    }
    let writePermit = cacheKey.map(cache.makeWritePermit(for:))
    do {
      let load = try await admittedResponse(
        for: request(url: reference.url, timeoutInterval: remainingLoadDuration),
        deadline: deadline,
        maximumByteCount: maximumByteCount
      )
      let admission = admittedImage(
        reference: reference,
        data: load.data,
        response: load.response,
        remainingByteCount: maximumByteCount,
        remainingPixelCount: remainingPixelCount
      )
      let retainedCacheKey: AuthorizedRemoteContentCacheKey? =
        if let admission, let cacheKey, let writePermit,
          (try? cache.save(admission.image, for: cacheKey, writePermit: writePermit)) == true
        {
          cacheKey
        } else {
          nil
        }
      return AdmissionAttempt(
        admission: admission,
        cachedKey: retainedCacheKey,
        receivedByteCount: load.receivedByteCount
      )
    } catch RemoteMessageContentError.responseTooLarge(let receivedByteCount),
      RemoteMessageContentError.transferFailed(let receivedByteCount)
    {
      return AdmissionAttempt(
        admission: nil,
        cachedKey: nil,
        receivedByteCount: receivedByteCount
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      if Task.isCancelled {
        throw CancellationError()
      }
      return AdmissionAttempt(admission: nil, cachedKey: nil, receivedByteCount: 0)
    }
  }

  private func admittedResponse(
    for request: URLRequest,
    deadline: TimeInterval,
    maximumByteCount: Int
  ) async throws -> RemoteMessageContentNetworkLoad {
    guard let requestGate, let messageId else {
      return try await response(for: request, maximumByteCount: maximumByteCount)
    }
    return try await requestGate.loadResource(
      for: request,
      messageId: messageId,
      deadline: deadline,
      monotonicTime: monotonicTime
    ) {
      let remainingLoadDuration = deadline - monotonicTime()
      guard remainingLoadDuration > 0, let url = request.url else {
        throw URLError(.timedOut)
      }
      return try await response(
        for: self.request(url: url, timeoutInterval: remainingLoadDuration),
        maximumByteCount: maximumByteCount
      )
    }
  }

  private func response(
    for request: URLRequest,
    maximumByteCount: Int
  ) async throws -> RemoteMessageContentNetworkLoad {
    if let fetch {
      let (data, response) = try await fetch(request, maximumByteCount)
      return RemoteMessageContentNetworkLoad(
        data: data,
        response: response,
        receivedByteCount: data.count
      )
    }
    return try await RemoteMessageContentNetworkClient().data(
      for: request,
      maximumByteCount: maximumByteCount
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
      let mimeType = MailboxMessageImagePolicy.normalizedSupportedMIMEType(httpResponse.mimeType)
    else {
      return nil
    }
    return admittedImage(
      reference: reference,
      data: data,
      mimeType: mimeType,
      remainingByteCount: remainingByteCount,
      remainingPixelCount: remainingPixelCount
    )
  }

  private func admittedImage(
    reference: RemoteMessageImageReference,
    data: Data,
    mimeType: String,
    remainingByteCount: Int,
    remainingPixelCount: Int
  ) -> RemoteMessageContentAdmission? {
    guard let mimeType = MailboxMessageImagePolicy.normalizedSupportedMIMEType(mimeType),
      let pixelCount = MailboxMessageImagePolicy.admittedPixelCount(
        data,
        mimeType: mimeType,
        remainingByteCount: remainingByteCount,
        remainingPixelCount: remainingPixelCount
      )
    else { return nil }
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
