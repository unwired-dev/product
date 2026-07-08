import Foundation

enum ConvexClientError: LocalizedError, Equatable {
  case missingConvexURL
  case httpError(statusCode: Int)
  case convexFailure(status: String)
  case decodeError

  var errorDescription: String? {
    switch self {
    case .missingConvexURL:
      return
        "Set CONVEX_URL in the scheme environment, apps/unwired-mail/.env.local, or local Xcode configuration."
    case .httpError(let statusCode):
      return "The backend returned HTTP status \(statusCode)."
    case .convexFailure(let status):
      return "The backend action returned status '\(status)'."
    case .decodeError:
      return "The backend returned an unexpected response."
    }
  }
}

final class ConvexClient {
  private let convexURL: URL?
  private let session: URLSession

  init(
    convexURL: URL? = BackendEnvironment.convexURL,
    session: URLSession = .shared
  ) {
    self.convexURL = convexURL
    self.session = session
  }

  func health() async throws -> HealthResponse {
    try await performAction(path: "health:health")
  }

  func connectProductAccount(
    identityToken: String,
    deviceIdentifier: String,
    platform: String
  ) async throws -> ProductAccountConnectResponse {
    try await performMutation(
      path: "productAccount:connect",
      args: ConnectProductAccountArgs(
        deviceIdentifier: deviceIdentifier,
        platform: platform
      ),
      identityToken: identityToken
    )
  }

  private func performAction<Response: Decodable>(
    path: String,
    args: some Encodable = EmptyConvexArgs()
  ) async throws -> Response {
    try await performRequest(
      endpoint: "api/action",
      path: path,
      args: args,
      identityToken: nil
    )
  }

  private func performMutation<Response: Decodable>(
    path: String,
    args: some Encodable,
    identityToken: String
  ) async throws -> Response {
    try await performRequest(
      endpoint: "api/mutation",
      path: path,
      args: args,
      identityToken: identityToken
    )
  }

  private func performRequest<Response: Decodable>(
    endpoint: String,
    path: String,
    args: some Encodable,
    identityToken: String?
  ) async throws -> Response {
    guard let convexURL else {
      throw ConvexClientError.missingConvexURL
    }

    var request = URLRequest(url: convexURL.appending(path: endpoint))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let identityToken {
      request.setValue("Bearer \(identityToken)", forHTTPHeaderField: "Authorization")
    }
    request.httpBody = try JSONEncoder().encode(
      ConvexFunctionRequest(path: path, args: AnyEncodable(args), format: "json")
    )

    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw ConvexClientError.decodeError
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
      throw ConvexClientError.httpError(statusCode: httpResponse.statusCode)
    }

    let functionResponse = try JSONDecoder().decode(
      ConvexFunctionEnvelope<Response>.self,
      from: data
    )
    guard functionResponse.status == "success" else {
      throw ConvexClientError.convexFailure(status: functionResponse.status)
    }

    return functionResponse.value
  }
}

private struct EmptyConvexArgs: Encodable {}

private struct ConnectProductAccountArgs: Encodable {
  let deviceIdentifier: String
  let platform: String
}

private struct ConvexFunctionRequest: Encodable {
  let path: String
  let args: AnyEncodable
  let format: String
}

private struct ConvexFunctionEnvelope<Value: Decodable>: Decodable {
  let status: String
  let value: Value
}

private struct AnyEncodable: Encodable {
  private let encodeValue: (Encoder) throws -> Void

  init(_ value: some Encodable) {
    self.encodeValue = value.encode
  }

  func encode(to encoder: Encoder) throws {
    try encodeValue(encoder)
  }
}

#if DEBUG
  enum ConvexClientTesting {
    static func makeSession(
      stubbing handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    )
      -> URLSession
    {
      URLProtocolStub.requestHandler = handler
      let configuration = URLSessionConfiguration.ephemeral
      configuration.protocolClasses = [URLProtocolStub.self]
      return URLSession(configuration: configuration)
    }
  }

  final class URLProtocolStub: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
      true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
      request
    }

    override func startLoading() {
      guard let handler = Self.requestHandler else {
        client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
        return
      }

      do {
        let (response, data) = try handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
      } catch {
        client?.urlProtocol(self, didFailWithError: error)
      }
    }

    override func stopLoading() {}
  }
#endif
