import CryptoKit
import Foundation

struct MailingListIdentity: Codable, Equatable, Hashable, Sendable {
  let rawValue: String

  var opaqueDismissalIdentifier: String {
    SHA256.hash(data: Data("unsubscribe:\(rawValue)".utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }
}

struct UnsubscribeMailtoMessage: Codable, Equatable, Sendable {
  let body: String
  let recipient: String
  let subject: String
}

enum UnsubscribeAction: Codable, Equatable, Sendable {
  case mailto(UnsubscribeMailtoMessage)
  case oneClick(URL)
  case web(URL)

  var title: String {
    switch self {
    case .oneClick:
      "Send Unsubscribe Request"
    case .mailto:
      "Email Unsubscribe Request"
    case .web:
      "Open Unsubscribe Page"
    }
  }
}

struct UnsubscribeSuggestion: Codable, Equatable, Sendable {
  let actions: [UnsubscribeAction]
  let mailingListIdentity: MailingListIdentity

  var preferredAction: UnsubscribeAction? {
    actions.first
  }
}

enum ProactiveMessageCard: Int, Comparable, Sendable {
  case contact = 1
  case unsubscribe = 2
  case event = 3

  static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  static func highestPriority(
    hasEvent: Bool,
    hasUnsubscribe: Bool,
    hasContact: Bool
  ) -> Self? {
    [
      hasEvent ? Self.event : nil,
      hasUnsubscribe ? Self.unsubscribe : nil,
      hasContact ? Self.contact : nil,
    ]
    .compactMap(\.self)
    .max()
  }
}

enum UnsubscribeSuggestionParser {
  private static let maximumHeaderValueLength = 16 * 1_024

  static func suggestion(headers: [(name: String, value: String)]) -> UnsubscribeSuggestion? {
    let listIdentifiers = values(named: "List-ID", in: headers)
    let unsubscribeValues = values(named: "List-Unsubscribe", in: headers)
    guard !unsubscribeValues.isEmpty else { return nil }

    let targets = unsubscribeValues.flatMap(extractTargets)
    let mailtoMessages = targets.compactMap(mailtoMessage)
    let webURLs = targets.compactMap(loadableHTTPSURL)
    let supportsOneClick = values(named: "List-Unsubscribe-Post", in: headers)
      .flatMap { $0.split(separator: ",") }
      .contains {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
          .caseInsensitiveCompare("List-Unsubscribe=One-Click") == .orderedSame
      }

    var actions: [UnsubscribeAction] = []
    if supportsOneClick, let oneClickURL = webURLs.first {
      actions.append(.oneClick(oneClickURL))
    }
    if let mailto = mailtoMessages.first {
      actions.append(.mailto(mailto))
    }
    if let webURL = webURLs.first {
      actions.append(.web(webURL))
    }
    guard !actions.isEmpty,
      let identity = mailingListIdentity(
        listIdentifiers: listIdentifiers,
        mailtoMessages: mailtoMessages,
        webURLs: webURLs
      )
    else { return nil }
    return UnsubscribeSuggestion(actions: actions, mailingListIdentity: identity)
  }

  private static func values(
    named name: String,
    in headers: [(name: String, value: String)]
  ) -> [String] {
    headers.compactMap { header in
      guard header.name.caseInsensitiveCompare(name) == .orderedSame else { return nil }
      return unfolded(header.value)
    }
  }

  private static func unfolded(_ value: String) -> String? {
    guard value.utf8.count <= maximumHeaderValueLength else { return nil }
    let unfolded = value.replacingOccurrences(
      of: #"\r?\n[\t ]+"#,
      with: " ",
      options: .regularExpression
    )
    guard !unfolded.contains("\r"), !unfolded.contains("\n") else { return nil }
    return unfolded.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func extractTargets(from value: String) -> [String] {
    let pattern = #"<([^<>]+)>"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    return expression.matches(in: value, range: range).compactMap { match in
      guard let targetRange = Range(match.range(at: 1), in: value) else { return nil }
      return String(value[targetRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  private static func loadableHTTPSURL(_ value: String) -> URL? {
    guard let components = URLComponents(string: value),
      components.scheme?.lowercased() == "https",
      components.host?.isEmpty == false,
      components.user == nil,
      components.password == nil,
      let url = components.url
    else { return nil }
    return url
  }

  private static func mailtoMessage(_ value: String) -> UnsubscribeMailtoMessage? {
    guard let components = URLComponents(string: value),
      components.scheme?.lowercased() == "mailto",
      components.user == nil,
      components.password == nil
    else { return nil }
    let recipient = components.path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !recipient.isEmpty, !recipient.contains("\r"), !recipient.contains("\n") else {
      return nil
    }
    let queryItems = components.queryItems ?? []
    func queryValue(named name: String) -> String {
      queryItems.first {
        $0.name.caseInsensitiveCompare(name) == .orderedSame
      }?.value ?? ""
    }
    let subject = queryValue(named: "subject")
    let body = queryValue(named: "body")
    guard !subject.contains("\r"), !subject.contains("\n") else { return nil }
    return UnsubscribeMailtoMessage(body: body, recipient: recipient, subject: subject)
  }

  private static func mailingListIdentity(
    listIdentifiers: [String],
    mailtoMessages: [UnsubscribeMailtoMessage],
    webURLs: [URL]
  ) -> MailingListIdentity? {
    if let listIdentifier = listIdentifiers.compactMap(normalizedListIdentifier).first {
      return MailingListIdentity(rawValue: "list-id:\(listIdentifier)")
    }
    if let recipient = mailtoMessages.first?.recipient.lowercased() {
      return MailingListIdentity(rawValue: "mailto:\(recipient)")
    }
    guard let url = webURLs.first,
      let host = url.host?.lowercased()
    else { return nil }
    let path = url.path.isEmpty ? "/" : url.path
    return MailingListIdentity(rawValue: "https:\(host)\(path)")
  }

  private static func normalizedListIdentifier(_ value: String) -> String? {
    let candidate: String
    if let opening = value.lastIndex(of: "<"),
      let closing = value[opening...].firstIndex(of: ">")
    {
      candidate = String(value[value.index(after: opening)..<closing])
    } else {
      candidate = value
    }
    let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty,
      normalized.utf8.count <= 998,
      !normalized.contains(where: \.isWhitespace),
      !normalized.contains("<"),
      !normalized.contains(">")
    else { return nil }
    return normalized
  }
}

enum UnsubscribeRequestError: LocalizedError, Equatable {
  case blockedDestination
  case outcomeUncertain
  case rejected(statusCode: Int)
  case tooManyRedirects

  var errorDescription: String? {
    switch self {
    case .blockedDestination:
      "The unsubscribe destination was blocked for safety."
    case .outcomeUncertain:
      "The request may have been sent, but no confirmation was received. Retry only if needed."
    case .rejected(let statusCode):
      "The unsubscribe service rejected the request (HTTP \(statusCode))."
    case .tooManyRedirects:
      "The unsubscribe destination redirected too many times."
    }
  }
}

struct UnsubscribeRequestService {
  typealias Resolver = (String) async throws -> [RemoteMessageContentIPAddress]
  typealias Transfer =
    (URLRequest, RemoteMessageContentIPAddress, String, Int) async throws
    -> RemoteMessageContentPinnedHTTPResponse

  private static let maximumResponseByteCount = 64 * 1_024
  private static let redirectStatusCodes = Set([301, 302, 303, 307, 308])
  private let monotonicTime: () -> TimeInterval
  private let resolver: Resolver
  private let transfer: Transfer

  init(
    resolver: @escaping Resolver = RemoteMessageContentIPAddress.resolve,
    transfer: @escaping Transfer = RemoteMessageContentPinnedHTTPSClient.transfer,
    monotonicTime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
  ) {
    self.resolver = resolver
    self.transfer = transfer
    self.monotonicTime = monotonicTime
  }

  func sendOneClick(to initialURL: URL) async throws {
    var currentURL = initialURL
    let deadline = monotonicTime() + 30
    var receivedByteCount = 0
    for redirectCount in 0...3 {
      try Task.checkCancellation()
      guard let host = safeHost(for: currentURL) else {
        throw UnsubscribeRequestError.blockedDestination
      }
      let remainingTime = deadline - monotonicTime()
      guard remainingTime > 0 else { throw URLError(.timedOut) }
      let addresses = try await publicAddresses(for: host)
      let response = try await send(
        oneClickRequest(url: currentURL, timeoutInterval: remainingTime),
        to: addresses[0],
        host: host,
        maximumResponseByteCount: Self.maximumResponseByteCount - receivedByteCount
      )
      receivedByteCount = try responseByteCount(
        afterAdding: response.body.count,
        to: receivedByteCount
      )

      guard Self.redirectStatusCodes.contains(response.statusCode) else {
        guard (200..<300).contains(response.statusCode) else {
          throw UnsubscribeRequestError.rejected(statusCode: response.statusCode)
        }
        return
      }
      guard redirectCount < 3 else { throw UnsubscribeRequestError.tooManyRedirects }
      currentURL = try redirectedURL(from: response, relativeTo: currentURL)
    }
    throw UnsubscribeRequestError.tooManyRedirects
  }

  private func oneClickRequest(url: URL, timeoutInterval: TimeInterval) -> URLRequest {
    var request = URLRequest(
      url: url,
      cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: timeoutInterval
    )
    request.httpMethod = "POST"
    request.httpBody = Data("List-Unsubscribe=One-Click".utf8)
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("text/plain, */*;q=0.1", forHTTPHeaderField: "Accept")
    return request
  }

  private func publicAddresses(
    for host: String
  ) async throws -> [RemoteMessageContentIPAddress] {
    let addresses: [RemoteMessageContentIPAddress]
    do {
      addresses = try await resolver(host)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw UnsubscribeRequestError.blockedDestination
    }
    guard !addresses.isEmpty, addresses.allSatisfy(\.isPublic) else {
      throw UnsubscribeRequestError.blockedDestination
    }
    return addresses
  }

  private func send(
    _ request: URLRequest,
    to address: RemoteMessageContentIPAddress,
    host: String,
    maximumResponseByteCount: Int
  ) async throws -> RemoteMessageContentPinnedHTTPResponse {
    do {
      return try await transfer(request, address, host, maximumResponseByteCount)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw UnsubscribeRequestError.outcomeUncertain
    }
  }

  private func responseByteCount(afterAdding addedCount: Int, to currentCount: Int) throws -> Int {
    let (newByteCount, overflow) = currentCount.addingReportingOverflow(addedCount)
    guard !overflow, newByteCount <= Self.maximumResponseByteCount else {
      throw UnsubscribeRequestError.outcomeUncertain
    }
    return newByteCount
  }

  private func redirectedURL(
    from response: RemoteMessageContentPinnedHTTPResponse,
    relativeTo currentURL: URL
  ) throws -> URL {
    guard
      let location = response.headerFields.first(where: {
        $0.key.caseInsensitiveCompare("Location") == .orderedSame
      })?.value,
      let redirectedURL = URL(string: location, relativeTo: currentURL)?.absoluteURL,
      safeHost(for: redirectedURL) != nil
    else { throw UnsubscribeRequestError.blockedDestination }
    return redirectedURL
  }

  private func safeHost(for url: URL) -> String? {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.scheme?.lowercased() == "https",
      components.user == nil,
      components.password == nil,
      let host = components.host,
      !host.isEmpty
    else { return nil }
    return host
  }
}
