import Foundation

// An RFC 8058 one-click unsubscribe request (ADR 0044), sent once over the remote-content
// transport: the same destination checks, pinned public address, TLS host check, redirect bound
// and deadline, carrying only the standards-defined body.
struct OneClickUnsubscribe: Sendable {
  enum Outcome: String, Sendable {
    // The server answered 2xx.
    case sent
    // Nothing was sent, or the server refused the request.
    case failed
    // The request may have reached the server without a usable answer; it is never resent.
    case uncertain
  }

  var fetcher = RemoteContentFetcher()

  func send(_ url: URL) async -> Outcome {
    var current = url
    for _ in 0...RemoteContentFetcher.redirectLimit {
      guard let destination = try? await destination(current) else { return .failed }
      let raw: Data
      do {
        raw = try await fetcher.exchange(destination)
      } catch RemoteContentError.unavailable {
        return .failed
      } catch {
        return .uncertain
      }
      guard let response = try? Self.finalResponse(raw) else { return .uncertain }
      switch response.status {
      case 200..<300:
        return .sent
      // Only these repeat the POST; the request was not processed where it was sent.
      case 307, 308:
        guard let location = response.headers["location"],
          let next = URL(string: location, relativeTo: current)?.absoluteURL
        else { return .failed }
        current = next
      // Another redirect answers a POST that the server may have processed.
      case 300..<400:
        return .uncertain
      default:
        return .failed
      }
    }
    return .failed
  }

  // The checked destination; name resolution has no deadline of its own.
  private func destination(_ url: URL) async throws -> RemoteContentFetcher.Destination {
    try fetcher.budget?.checkDeadline()
    return try await withThrowingTaskGroup(of: RemoteContentFetcher.Destination.self) { group in
      group.addTask { try await fetcher.destination(url, request: Self.request) }
      group.addTask {
        try await Task.sleep(for: max(.zero, fetcher.budget?.timeLeft ?? .seconds(30)))
        throw RemoteContentError.unavailable
      }
      defer { group.cancelAll() }
      guard let destination = try await group.next() else { throw RemoteContentError.unavailable }
      return destination
    }
  }

  // The answer after any interim 1xx answers, which only precede it (RFC 9110 §15.2).
  static func finalResponse(_ raw: Data) throws -> RemoteContentFetcher.Response {
    var rest = raw
    while true {
      let response = try RemoteContentFetcher.response(rest)
      guard (100..<200).contains(response.status),
        let end = rest.firstRange(of: Data("\r\n\r\n".utf8))
      else { return response }
      rest = Data(rest[end.upperBound...])
    }
  }

  static func request(target: String, authority: String) -> String {
    let body = "List-Unsubscribe=One-Click"
    return "POST \(target) HTTP/1.1\r\nHost: \(authority)\r\n"
      + "Content-Type: application/x-www-form-urlencoded\r\nContent-Length: \(body.utf8.count)\r\n"
      + "Connection: close\r\n\r\n" + body
  }
}
