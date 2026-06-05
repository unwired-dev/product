import Foundation

struct HealthResponse: Decodable, Equatable {
  let bootstrapVersion: Int
  let serverTime: Int64
  let service: String
  let status: String
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
  case unsuccessfulStatus(String)

  var errorDescription: String? {
    switch self {
    case .unsuccessfulStatus(let status):
      return "The backend health action returned status '\(status)'."
    }
  }
}

final class ConvexBackendHealthService: BackendHealthChecking {
  private let client: ConvexClient

  init(client: ConvexClient = ConvexClient()) {
    self.client = client
  }

  func health() async throws -> HealthResponse {
    let response = try await client.health()
    guard response.status == "ok" else {
      throw BackendHealthError.unsuccessfulStatus(response.status)
    }

    return response
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
    bootstrapVersion: 1,
    serverTime: 1_781_200_000_000,
    service: "private-email-api",
    status: "ok"
  )
}
