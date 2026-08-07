import Foundation
import Network
import Security

enum RemoteMessageContentNetworkError: Error, Equatable {
  case blockedDestination
  case invalidResponse
  case tooManyRedirects
  case unresolvedDestination
}

struct RemoteMessageContentPinnedHTTPResponse: Equatable, Sendable {
  let body: Data
  let headerFields: [String: String]
  let statusCode: Int
}

struct RemoteMessageContentNetworkClient {
  typealias Resolver = (String) async throws -> [RemoteMessageContentIPAddress]
  typealias Transfer =
    (URLRequest, RemoteMessageContentIPAddress, String, Int) async throws
    -> RemoteMessageContentPinnedHTTPResponse

  private static let redirectStatusCodes = Set([301, 302, 303, 307, 308])
  private let resolver: Resolver
  private let transfer: Transfer

  init(
    resolver: @escaping Resolver = RemoteMessageContentIPAddress.resolve,
    transfer: @escaping Transfer = RemoteMessageContentPinnedHTTPSClient.transfer
  ) {
    self.resolver = resolver
    self.transfer = transfer
  }

  // swiftlint:disable:next function_body_length
  func data(
    for request: URLRequest,
    maximumByteCount: Int
  ) async throws -> (Data, URLResponse) {
    var currentRequest = RemoteMessageContentRedirectPolicy.isolatedRequest(request)
    for redirectCount in 0...3 {
      try Task.checkCancellation()
      guard RemoteMessageContentPolicy.isLoadableHTTPSURL(currentRequest.url),
        let url = currentRequest.url,
        let host = url.host
      else { throw RemoteMessageContentNetworkError.blockedDestination }
      let addresses = try await resolver(host)
      guard !addresses.isEmpty, addresses.allSatisfy(\.isPublic) else {
        throw RemoteMessageContentNetworkError.blockedDestination
      }
      let response = try await transfer(
        currentRequest,
        addresses[0],
        host,
        maximumByteCount
      )
      guard Self.redirectStatusCodes.contains(response.statusCode) else {
        guard
          let urlResponse = HTTPURLResponse(
            url: url,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: response.headerFields
          )
        else { throw RemoteMessageContentNetworkError.invalidResponse }
        return (response.body, urlResponse)
      }
      guard redirectCount < 3 else {
        throw RemoteMessageContentNetworkError.tooManyRedirects
      }
      guard let location = response.headerValue("location"),
        let redirectURL = URL(string: location, relativeTo: url)?.absoluteURL
      else { throw RemoteMessageContentNetworkError.invalidResponse }
      var redirectRequest = URLRequest(
        url: redirectURL,
        cachePolicy: .reloadIgnoringLocalCacheData,
        timeoutInterval: currentRequest.timeoutInterval
      )
      redirectRequest.httpMethod = "GET"
      redirectRequest.setValue(
        currentRequest.value(forHTTPHeaderField: "Accept"),
        forHTTPHeaderField: "Accept"
      )
      guard
        let isolatedRedirect = RemoteMessageContentRedirectPolicy.redirectedRequest(
          redirectRequest
        )
      else { throw RemoteMessageContentNetworkError.blockedDestination }
      currentRequest = isolatedRedirect
    }
    throw RemoteMessageContentNetworkError.tooManyRedirects
  }
}

extension RemoteMessageContentPinnedHTTPResponse {
  fileprivate func headerValue(_ name: String) -> String? {
    headerFields.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
  }
}

enum RemoteMessageContentPinnedHTTPSClient {
  private static let maximumHeaderAndFramingByteCount = 1_024 * 1_024

  static func transfer(
    _ request: URLRequest,
    address: RemoteMessageContentIPAddress,
    tlsServerName: String,
    maximumByteCount: Int
  ) async throws -> RemoteMessageContentPinnedHTTPResponse {
    guard let url = request.url,
      let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 443))
    else { throw RemoteMessageContentNetworkError.invalidResponse }
    let tlsOptions = NWProtocolTLS.Options()
    tlsServerName.withCString {
      sec_protocol_options_set_tls_server_name(tlsOptions.securityProtocolOptions, $0)
    }
    sec_protocol_options_set_min_tls_protocol_version(
      tlsOptions.securityProtocolOptions,
      .TLSv12
    )
    sec_protocol_options_add_tls_application_protocol(
      tlsOptions.securityProtocolOptions,
      "http/1.1"
    )
    let connection = NWConnection(
      host: NWEndpoint.Host(address.literal),
      port: port,
      using: NWParameters(tls: tlsOptions)
    )
    let controller = RemoteMessageContentConnectionController(connection: connection)
    let timeout = min(30, max(0.001, request.timeoutInterval))
    return try await withTaskCancellationHandler {
      try await controller.perform(
        request: serializedRequest(request, tlsServerName: tlsServerName),
        maximumRawByteCount: maximumByteCount + maximumHeaderAndFramingByteCount,
        maximumBodyByteCount: maximumByteCount,
        timeout: timeout
      )
    } onCancel: {
      controller.cancel()
    }
  }

  private static func serializedRequest(
    _ request: URLRequest,
    tlsServerName: String
  ) throws -> Data {
    guard let url = request.url,
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { throw RemoteMessageContentNetworkError.invalidResponse }
    let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
    let target = components.percentEncodedQuery.map { "\(path)?\($0)" } ?? path
    let host = tlsServerName.contains(":") ? "[\(tlsServerName)]" : tlsServerName
    let authority = url.port.map { $0 == 443 ? host : "\(host):\($0)" } ?? host
    var headerFields = request.allHTTPHeaderFields ?? [:]
    let privateHeaders = [
      "authorization", "connection", "content-length", "cookie", "host", "referer",
    ]
    for field in Array(headerFields.keys) where privateHeaders.contains(field.lowercased()) {
      headerFields.removeValue(forKey: field)
    }
    headerFields["Connection"] = "close"
    headerFields["Host"] = authority
    let safeHeaders = headerFields.sorted { $0.key.lowercased() < $1.key.lowercased() }
    guard
      safeHeaders.allSatisfy({ field, value in
        !field.contains("\r") && !field.contains("\n")
          && !value.contains("\r") && !value.contains("\n")
      })
    else { throw RemoteMessageContentNetworkError.invalidResponse }
    let lines =
      ["GET \(target) HTTP/1.1"]
      + safeHeaders.map { "\($0.key): \($0.value)" }
      + ["", ""]
    return Data(lines.joined(separator: "\r\n").utf8)
  }
}

private final class RemoteMessageContentConnectionController: @unchecked Sendable {
  private let connection: NWConnection
  private let lock = NSLock()
  private var timedOut = false

  init(connection: NWConnection) {
    self.connection = connection
  }

  func perform(
    request: Data,
    maximumRawByteCount: Int,
    maximumBodyByteCount: Int,
    timeout: TimeInterval
  ) async throws -> RemoteMessageContentPinnedHTTPResponse {
    let queue = DispatchQueue(label: "dev.unwired.mail.remote-message-content")
    let timeoutWork = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.lock.withLock { self.timedOut = true }
      self.connection.cancel()
    }
    queue.asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
    defer {
      timeoutWork.cancel()
      connection.cancel()
    }
    do {
      try await waitUntilReady(on: queue)
      try await send(request)
      let rawResponse = try await receive(maximumByteCount: maximumRawByteCount)
      return try Self.parseResponse(rawResponse, maximumBodyByteCount: maximumBodyByteCount)
    } catch {
      if Task.isCancelled { throw CancellationError() }
      if lock.withLock({ timedOut }) { throw URLError(.timedOut) }
      if error is CancellationError { throw CancellationError() }
      throw error
    }
  }

  func cancel() {
    connection.cancel()
  }

  private func waitUntilReady(on queue: DispatchQueue) async throws {
    try await withCheckedThrowingContinuation { continuation in
      let result = RemoteMessageContentOneShotContinuation<Void>(continuation)
      connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
          result.resume(returning: ())
        case .failed(let error):
          result.resume(throwing: error)
        case .cancelled:
          result.resume(throwing: CancellationError())
        default:
          break
        }
      }
      connection.start(queue: queue)
    }
  }

  private func send(_ data: Data) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      connection.send(
        content: data,
        completion: .contentProcessed { error in
          if let error {
            continuation.resume(throwing: error)
          } else {
            continuation.resume()
          }
        })
    }
  }

  private func receive(maximumByteCount: Int) async throws -> Data {
    var response = Data()
    while true {
      let part: (Data?, Bool) = try await withCheckedThrowingContinuation { continuation in
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) {
          if let error = $3 {
            continuation.resume(throwing: error)
          } else {
            continuation.resume(returning: ($0, $2))
          }
        }
      }
      if let data = part.0 {
        response.append(data)
        guard response.count <= maximumByteCount else {
          throw RemoteMessageContentError.responseTooLarge(
            receivedByteCount: response.count
          )
        }
      }
      if part.1 { return response }
    }
  }

  private static func parseResponse(
    _ data: Data,
    maximumBodyByteCount: Int
  ) throws -> RemoteMessageContentPinnedHTTPResponse {
    let delimiter = Data("\r\n\r\n".utf8)
    guard let headerRange = data.range(of: delimiter),
      let header = String(data: data[..<headerRange.lowerBound], encoding: .isoLatin1)
    else { throw RemoteMessageContentNetworkError.invalidResponse }
    let lines = header.components(separatedBy: "\r\n")
    guard let statusLine = lines.first else {
      throw RemoteMessageContentNetworkError.invalidResponse
    }
    let statusParts = statusLine.split(separator: " ", maxSplits: 2)
    guard statusParts.count >= 2,
      statusParts[0].hasPrefix("HTTP/1."),
      let statusCode = Int(statusParts[1])
    else { throw RemoteMessageContentNetworkError.invalidResponse }
    var headerFields: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let separator = line.firstIndex(of: ":") else {
        throw RemoteMessageContentNetworkError.invalidResponse
      }
      let name = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
      let value = String(line[line.index(after: separator)...])
        .trimmingCharacters(in: .whitespaces)
      guard !name.isEmpty else { throw RemoteMessageContentNetworkError.invalidResponse }
      headerFields[name] = headerFields[name].map { "\($0), \(value)" } ?? value
    }
    let encodedBody = Data(data[headerRange.upperBound...])
    let body: Data
    if headerFields.containsValue(whereHeaderNamed: "transfer-encoding", contains: "chunked") {
      body = try decodeChunkedBody(encodedBody, maximumByteCount: maximumBodyByteCount)
    } else if let length = headerFields.value(forHeaderNamed: "content-length").flatMap(Int.init) {
      guard length >= 0, length <= maximumBodyByteCount, encodedBody.count >= length else {
        throw RemoteMessageContentError.responseTooLarge(receivedByteCount: encodedBody.count)
      }
      body = Data(encodedBody.prefix(length))
    } else {
      body = encodedBody
    }
    guard body.count <= maximumBodyByteCount else {
      throw RemoteMessageContentError.responseTooLarge(receivedByteCount: body.count)
    }
    return RemoteMessageContentPinnedHTTPResponse(
      body: body,
      headerFields: headerFields,
      statusCode: statusCode
    )
  }

  private static func decodeChunkedBody(
    _ data: Data,
    maximumByteCount: Int
  ) throws -> Data {
    let delimiter = Data("\r\n".utf8)
    var cursor = data.startIndex
    var body = Data()
    while true {
      guard let sizeRange = data[cursor...].range(of: delimiter),
        let sizeLine = String(data: data[cursor..<sizeRange.lowerBound], encoding: .ascii),
        let sizeToken = sizeLine.split(separator: ";", maxSplits: 1).first,
        let size = Int(sizeToken.trimmingCharacters(in: .whitespaces), radix: 16)
      else { throw RemoteMessageContentNetworkError.invalidResponse }
      cursor = sizeRange.upperBound
      if size == 0 { return body }
      guard size <= maximumByteCount - body.count,
        data.distance(from: cursor, to: data.endIndex) >= size + delimiter.count
      else {
        throw RemoteMessageContentError.responseTooLarge(receivedByteCount: body.count + size)
      }
      let end = data.index(cursor, offsetBy: size)
      body.append(data[cursor..<end])
      guard data[end..<data.endIndex].starts(with: delimiter) else {
        throw RemoteMessageContentNetworkError.invalidResponse
      }
      cursor = data.index(end, offsetBy: delimiter.count)
    }
  }
}

private final class RemoteMessageContentOneShotContinuation<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, Error>?

  init(_ continuation: CheckedContinuation<Value, Error>) {
    self.continuation = continuation
  }

  func resume(returning value: Value) {
    lock.withLock {
      continuation?.resume(returning: value)
      continuation = nil
    }
  }

  func resume(throwing error: Error) {
    lock.withLock {
      continuation?.resume(throwing: error)
      continuation = nil
    }
  }
}

extension Dictionary where Key == String, Value == String {
  fileprivate func value(forHeaderNamed name: String) -> String? {
    first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
  }

  fileprivate func containsValue(whereHeaderNamed name: String, contains needle: String) -> Bool {
    value(forHeaderNamed: name)?.lowercased().contains(needle.lowercased()) == true
  }
}
