import Foundation
import Network
import Security

// Remote Message Content is fetched outside WebKit, one authorized image at a time: HTTPS only,
// no cookies, credentials, referrer or shared session, to one validated public address pinned for
// the connection while TLS authenticates the original host name. Every redirect repeats the checks.
struct RemoteContentFetcher: Sendable {
  static let byteLimit = 5 * 1024 * 1024
  static let headerLimit = 64 * 1024
  static let redirectLimit = 3

  // One connection: the pinned address, the name TLS must authenticate, and the request bytes.
  struct Destination: Sendable {
    let address: IPAddress
    let host: String
    let port: UInt16
    let request: Data
  }

  var resolve: @Sendable (String) async throws -> [IPAddress] = RemoteAddress.resolve
  var permits: @Sendable (IPAddress) -> Bool = RemoteAddress.isPublic
  var exchange: @Sendable (Destination) async throws -> Data = { try await RemoteTransport().exchange($0) }
  var budget: RemoteContentBudget?

  // The image bytes of a 200 response, following at most three redirects.
  func fetch(_ url: URL) async throws -> Data {
    try await withThrowingTaskGroup(of: Data.self) { group in
      group.addTask { try await retrieve(url) }
      group.addTask {
        try await Task.sleep(for: max(.zero, budget?.timeLeft ?? .seconds(30)))
        throw RemoteContentError.unavailable
      }
      defer { group.cancelAll() }
      guard let bytes = try await group.next() else { throw RemoteContentError.unavailable }
      return bytes
    }
  }

  private func retrieve(_ url: URL) async throws -> Data {
    var current = url
    for _ in 0...Self.redirectLimit {
      try Task.checkCancellation()
      try budget?.checkDeadline()
      let destination = try await destination(current)
      try Task.checkCancellation()
      try budget?.checkDeadline()
      let response = try Self.response(try await exchange(destination))
      if response.status == 200 { return response.body }
      guard [301, 302, 303, 307, 308].contains(response.status),
        let location = response.headers["location"],
        let next = URL(string: location, relativeTo: current)?.absoluteURL
      else { throw RemoteContentError.refused }
      current = next
    }
    throw RemoteContentError.refused
  }

  func destination(_ url: URL) async throws -> Destination {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
      components.scheme?.lowercased() == "https", components.user == nil,
      components.password == nil, let rawHost = components.host, !rawHost.isEmpty,
      rawHost.allSatisfy(\.isASCII)
    else { throw RemoteContentError.refused }
    let port = components.port ?? 443
    guard (1...65535).contains(port) else { throw RemoteContentError.refused }
    let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    let addresses: [IPAddress]
    if let literal = IPv4Address(host).map({ $0 as IPAddress }) ?? IPv6Address(host) {
      addresses = [literal]
    } else {
      addresses = try await resolve(host)
    }
    // One non-public answer refuses the name: a rebinding resolver cannot mix in a private target.
    guard let address = addresses.first, addresses.allSatisfy(permits) else {
      throw RemoteContentError.refused
    }
    let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
    let target = path + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
    guard !target.contains(where: { $0.isWhitespace || $0.isNewline }) else {
      throw RemoteContentError.refused
    }
    let authority = (host.contains(":") ? "[\(host)]" : host) + (port == 443 ? "" : ":\(port)")
    let request =
      "GET \(target) HTTP/1.1\r\nHost: \(authority)\r\n"
      + "Accept: image/png,image/jpeg,image/gif,image/webp\r\nAccept-Encoding: identity\r\n"
      + "Connection: close\r\n\r\n"
    return Destination(address: address, host: host, port: UInt16(port), request: Data(request.utf8))
  }

  struct Response {
    let status: Int
    let headers: [String: String]
    let body: Data
  }

  // An HTTP/1.1 response read to the end of the connection, its body delimited by length,
  // chunking or the close, within the byte limit.
  static func response(_ raw: Data) throws -> Response {
    guard let end = raw.firstRange(of: Data("\r\n\r\n".utf8)), end.lowerBound <= headerLimit,
      let head = String(data: raw[..<end.lowerBound], encoding: .isoLatin1)
    else { throw RemoteContentError.unavailable }
    var lines = head.components(separatedBy: "\r\n")
    let statusLine = lines.removeFirst().split(separator: " ", maxSplits: 2)
    guard statusLine.count >= 2, statusLine[0].hasPrefix("HTTP/1."),
      let status = Int(statusLine[1])
    else { throw RemoteContentError.unavailable }
    var headers: [String: String] = [:]
    for line in lines {
      guard let colon = line.firstIndex(of: ":") else { throw RemoteContentError.unavailable }
      let name = line[..<colon].lowercased()
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      // Conflicting framing headers could make two readers disagree on the body.
      if ["content-length", "transfer-encoding"].contains(name), headers[name] != nil {
        throw RemoteContentError.unavailable
      }
      headers[name] = value
    }
    let rest = raw[end.upperBound...]
    let body: Data
    guard headers["transfer-encoding"] == nil || headers["content-length"] == nil else {
      throw RemoteContentError.unavailable
    }
    if headers["transfer-encoding"]?.lowercased() == "chunked" {
      body = try dechunk(rest)
    } else if let declared = headers["content-length"] {
      guard let length = Int(declared), length >= 0, length <= rest.count else {
        throw RemoteContentError.unavailable
      }
      body = rest.prefix(length)
    } else if headers["transfer-encoding"] == nil {
      body = rest
    } else {
      throw RemoteContentError.unavailable
    }
    guard body.count <= byteLimit else { throw RemoteContentError.refused }
    return Response(status: status, headers: headers, body: Data(body))
  }

  private static func dechunk(_ data: Data) throws -> Data {
    var body = Data()
    var index = data.startIndex
    let separator = Data("\r\n".utf8)
    while true {
      guard let line = data[index...].firstRange(of: separator),
        let text = String(data: data[index..<line.lowerBound], encoding: .ascii),
        let token = text.split(separator: ";", omittingEmptySubsequences: false).first,
        !token.isEmpty,
        token.allSatisfy(\.isHexDigit),
        let size = Int(token, radix: 16), size >= 0
      else { throw RemoteContentError.unavailable }
      index = line.upperBound
      if size == 0 {
        guard data[index...].starts(with: separator) else { throw RemoteContentError.unavailable }
        return body
      }
      guard size <= byteLimit - body.count,
        data.distance(from: index, to: data.endIndex) >= 2,
        size <= data.distance(from: index, to: data.endIndex) - 2,
        data[data.index(index, offsetBy: size)...].starts(with: separator)
      else { throw RemoteContentError.unavailable }
      body.append(data[index..<data.index(index, offsetBy: size)])
      index = data.index(index, offsetBy: size + 2)
    }
  }
}

enum RemoteContentError: Error {
  // The destination or response is not allowed; retrying the same reference cannot succeed.
  case refused
  // The server could not be reached or answered unreadably.
  case unavailable
}

// One presentation's transfer budget, shared by every request and redirect. Reserve before a
// receive so concurrent connections cannot spend the same bytes; refund only bytes not received.
final class RemoteContentBudget: @unchecked Sendable {
  private let lock = NSLock()
  private var remaining: Int
  private let deadline: ContinuousClock.Instant

  init(bytes: Int = 20 * 1024 * 1024, timeout: Duration = .seconds(30)) {
    remaining = bytes
    deadline = ContinuousClock.now.advanced(by: timeout)
  }

  var timeLeft: Duration { ContinuousClock.now.duration(to: deadline) }

  func checkDeadline() throws {
    guard timeLeft > .zero else { throw RemoteContentError.unavailable }
  }

  func reserve(upTo count: Int) throws -> Int {
    try checkDeadline()
    return try lock.withLock {
      guard remaining > 0 else { throw RemoteContentError.refused }
      let reserved = min(count, remaining)
      remaining -= reserved
      return reserved
    }
  }

  func returnUnused(_ count: Int) { lock.withLock { remaining += count } }
}

enum RemoteAddress {
  // Globally routable unicast only: no loopback, private, shared, link-local, documentation,
  // benchmarking, multicast or reserved space, and IPv6 transition forms only for public IPv4.
  static func isPublic(_ address: IPAddress) -> Bool {
    let bytes = [UInt8](address.rawValue)
    if bytes.count == 4 { return isPublicIPv4(bytes) }
    guard bytes.count == 16 else { return false }
    // NAT64 (64:ff9b::/96) carries an IPv4 destination, as IPv6-only networks synthesize it.
    if bytes[0..<12] == [0, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0] {
      return isPublicIPv4(Array(bytes[12...]))
    }
    guard bytes[0] & 0xe0 == 0x20 else { return false }  // 2000::/3
    let prefix = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    if prefix == 0x3fff && bytes[2] & 0xf0 == 0 { return false }  // 3fff::/20 documentation
    if prefix == 0x2002 { return false }  // 6to4
    if prefix == 0x2001 {
      // 2001::/23 protocol assignments (Teredo, ORCHID, benchmarking) and 2001:db8::/32.
      if bytes[2] < 0x02 { return false }
      if bytes[2] == 0x0d && bytes[3] == 0xb8 { return false }
    }
    return true
  }

  private static func isPublicIPv4(_ b: [UInt8]) -> Bool {
    switch (b[0], b[1], b[2]) {
    case (0, _, _), (10, _, _), (127, _, _), (169, 254, _), (192, 168, _): return false
    case (100, 64...127, _), (172, 16...31, _), (198, 18...19, _): return false
    case (192, 0, 0), (192, 0, 2), (192, 88, 99), (198, 51, 100), (203, 0, 113): return false
    case (224...255, _, _): return false
    default: return true
    }
  }

  static func resolve(_ host: String) async throws -> [IPAddress] {
    let resolution = Resolution()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        resolution.start(continuation, host: host)
      }
    } onCancel: {
      resolution.cancel()
    }
  }

  // getaddrinfo may finish after cancellation; its result cannot start a connection then.
  private final class Resolution: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[IPAddress], any Error>?
    private var cancelled = false

    func start(_ continuation: CheckedContinuation<[IPAddress], any Error>, host: String) {
      let stopped = lock.withLock {
        if cancelled { return true }
        self.continuation = continuation
        return false
      }
      if stopped {
        continuation.resume(throwing: CancellationError())
        return
      }
      Task.detached(priority: .userInitiated) {
        self.finish(Result { try RemoteAddress.resolveSynchronously(host) })
      }
    }

    func cancel() {
      lock.withLock { cancelled = true }
      finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<[IPAddress], any Error>) {
      let pending = lock.withLock {
        let pending = continuation
        continuation = nil
        return pending
      }
      pending?.resume(with: result)
    }
  }

  private static func resolveSynchronously(_ host: String) throws -> [IPAddress] {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM
    hints.ai_flags = AI_ADDRCONFIG
    var list: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else {
      throw RemoteContentError.unavailable
    }
    defer { freeaddrinfo(first) }
    var addresses: [IPAddress] = []
    for entry in sequence(first: first, next: { $0.pointee.ai_next }) {
      guard let address = entry.pointee.ai_addr else { continue }
      switch Int32(address.pointee.sa_family) {
      case AF_INET:
        var value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        addresses.append(IPv4Address(Data(bytes: &value, count: 4))!)
      case AF_INET6:
        var value = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
        addresses.append(IPv6Address(Data(bytes: &value, count: 16))!)
      default:
        continue
      }
    }
    return addresses
  }
}

// One HTTPS exchange over Network.framework to an already validated address, never through a
// proxy, with the TLS server name and certificate check bound to the original host.
struct RemoteTransport: Sendable {
  // Tests trust their own fixture authority at a fixed instant; production uses system trust now.
  var anchors: [SecCertificate] = []
  var verifyDate: Date?
  var timeout: Duration = .seconds(30)
  var budget: RemoteContentBudget?

  func exchange(_ destination: RemoteContentFetcher.Destination) async throws -> Data {
    try Task.checkCancellation()
    try budget?.checkDeadline()
    let queue = DispatchQueue(label: "dev.unwired.remote-content")
    let tls = NWProtocolTLS.Options()
    let security = tls.securityProtocolOptions
    sec_protocol_options_set_tls_server_name(security, destination.host)
    sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
    sec_protocol_options_add_tls_application_protocol(security, "http/1.1")
    let anchors = anchors
    let verifyDate = verifyDate
    sec_protocol_options_set_verify_block(
      security,
      { _, trust, complete in
        let trust = sec_trust_copy_ref(trust).takeRetainedValue()
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, destination.host as CFString))
        if !anchors.isEmpty { SecTrustSetAnchorCertificates(trust, anchors as CFArray) }
        if let verifyDate { SecTrustSetVerifyDate(trust, verifyDate as CFDate) }
        complete(SecTrustEvaluateWithError(trust, nil))
      }, queue)
    let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    parameters.preferNoProxies = true
    guard let port = NWEndpoint.Port(rawValue: destination.port) else {
      throw RemoteContentError.refused
    }
    let host: NWEndpoint.Host =
      (destination.address as? IPv4Address).map { .ipv4($0) }
      ?? .ipv6(destination.address as! IPv6Address)
    let connection = NWConnection(to: .hostPort(host: host, port: port), using: parameters)
    let exchange = Exchange(connection: connection, request: destination.request, budget: budget)
    return try await withThrowingTaskGroup(of: Data.self) { group in
      group.addTask {
        try await withTaskCancellationHandler {
          try await withCheckedThrowingContinuation { exchange.start($0, queue: queue) }
        } onCancel: {
          connection.cancel()
        }
      }
      group.addTask {
        try await Task.sleep(for: min(timeout, budget?.timeLeft ?? timeout))
        throw RemoteContentError.unavailable
      }
      defer {
        group.cancelAll()
        connection.cancel()
      }
      guard let data = try await group.next() else { throw RemoteContentError.unavailable }
      return data
    }
  }

  // Sends the request once ready and reads until the server closes, refusing an oversized reply.
  private final class Exchange: @unchecked Sendable {
    private let connection: NWConnection
    private let request: Data
    private let budget: RemoteContentBudget?
    private let limit = RemoteContentFetcher.byteLimit + RemoteContentFetcher.headerLimit + 64 * 1024
    private var received = Data()
    private var continuation: CheckedContinuation<Data, any Error>?

    init(connection: NWConnection, request: Data, budget: RemoteContentBudget?) {
      self.connection = connection
      self.request = request
      self.budget = budget
    }

    // Runs on the exchange's serial queue only.
    func start(_ continuation: CheckedContinuation<Data, any Error>, queue: DispatchQueue) {
      self.continuation = continuation
      connection.stateUpdateHandler = { [self] state in
        switch state {
        case .ready:
          connection.send(
            content: request,
            completion: .contentProcessed { [self] error in
              if error != nil { finish(.failure(RemoteContentError.unavailable)) } else { receive() }
            })
        case .failed, .waiting:
          finish(.failure(RemoteContentError.unavailable))
        case .cancelled:
          finish(.failure(CancellationError()))
        default:
          break
        }
      }
      connection.start(queue: queue)
    }

    private func receive() {
      let reserved: Int
      do { reserved = try budget?.reserve(upTo: 64 * 1024) ?? 64 * 1024 } catch {
        finish(.failure(error))
        return
      }
      connection.receive(minimumIncompleteLength: 1, maximumLength: reserved) {
        [self] data, _, complete, error in
        budget?.returnUnused(reserved - (data?.count ?? 0))
        if let data { received.append(data) }
        if received.count > limit {
          finish(.failure(RemoteContentError.refused))
        } else if complete {
          finish(.success(received))
        } else if error != nil {
          finish(.failure(RemoteContentError.unavailable))
        } else {
          receive()
        }
      }
    }

    private func finish(_ result: Result<Data, any Error>) {
      guard let continuation else { return }
      self.continuation = nil
      connection.cancel()
      continuation.resume(with: result)
    }
  }
}
