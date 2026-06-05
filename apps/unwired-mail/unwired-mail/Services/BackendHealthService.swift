import Foundation

struct HealthResponse: Decodable, Equatable {
  let service: String
  let status: String
  let bootstrapVersion: Int
  let serverTime: Int64
}

enum BackendHealthState: Equatable {
  case loading
  case healthy(HealthResponse)
  case failed(String)
}

protocol BackendHealthChecking {
  func health() async throws -> HealthResponse
}

enum BackendHealthError: LocalizedError, Equatable {
  case missingConvexURL
  case invalidResponse
  case unsuccessfulStatus(String)

  var errorDescription: String? {
    switch self {
    case .missingConvexURL:
      return "Set CONVEX_URL in the scheme environment or local Xcode configuration."
    case .invalidResponse:
      return "The backend returned an unexpected health response."
    case .unsuccessfulStatus(let status):
      return "The backend health action returned status '\(status)'."
    }
  }
}

final class ConvexBackendHealthService: BackendHealthChecking {
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
    guard let convexURL else {
      throw BackendHealthError.missingConvexURL
    }

    var request = URLRequest(url: convexURL.appending(path: "api/action"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(
      ConvexActionRequest(path: "health:health", args: [:], format: "json")
    )

    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse,
      (200..<300).contains(httpResponse.statusCode)
    else {
      throw BackendHealthError.invalidResponse
    }

    let actionResponse = try JSONDecoder().decode(ConvexActionResponse.self, from: data)
    guard actionResponse.status == "success", actionResponse.value.status == "ok" else {
      throw BackendHealthError.unsuccessfulStatus(actionResponse.status)
    }

    return actionResponse.value
  }
}

private struct ConvexActionRequest: Encodable {
  let path: String
  let args: [String: String]
  let format: String
}

private struct ConvexActionResponse: Decodable {
  let status: String
  let value: HealthResponse
}

enum BackendEnvironment {
  static var convexURL: URL? {
    guard let rawValue = ProcessInfo.processInfo.environment["CONVEX_URL"],
      !rawValue.isEmpty
    else {
      return nil
    }

    return URL(string: rawValue)
  }
}

struct PreviewBackendHealthService: BackendHealthChecking {
  let result: Result<HealthResponse, Error>

  func health() async throws -> HealthResponse {
    try result.get()
  }
}

extension HealthResponse {
  static let preview = HealthResponse(
    service: "private-email-api",
    status: "ok",
    bootstrapVersion: 1,
    serverTime: 1_781_200_000_000
  )
}
