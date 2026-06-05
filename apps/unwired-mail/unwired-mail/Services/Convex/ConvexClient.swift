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
      return "The backend returned an unexpected action response."
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

  private func performAction<Response: Decodable>(
    path: String,
    args: [String: String] = [:]
  ) async throws -> Response {
    guard let convexURL else {
      throw ConvexClientError.missingConvexURL
    }

    var request = URLRequest(url: convexURL.appending(path: "api/action"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(
      ConvexActionRequest(path: path, args: args, format: "json")
    )

    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw ConvexClientError.decodeError
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
      throw ConvexClientError.httpError(statusCode: httpResponse.statusCode)
    }

    let actionResponse = try JSONDecoder().decode(
      ConvexActionEnvelope<Response>.self,
      from: data
    )
    guard actionResponse.status == "success" else {
      throw ConvexClientError.convexFailure(status: actionResponse.status)
    }

    return actionResponse.value
  }
}

private struct ConvexActionRequest: Encodable {
  let path: String
  let args: [String: String]
  let format: String
}

private struct ConvexActionEnvelope<Value: Decodable>: Decodable {
  let status: String
  let value: Value
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
