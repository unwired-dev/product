import Foundation
import Testing

@testable import unwired_mail

// swiftlint:disable non_optional_string_data_conversion

@Suite(.serialized)
final class BackendHealthServiceTests {
  @Test
  func testUnsuccessfulStatusMapsToDomainError() async {
    let client = ConvexClient(
      convexURL: URL(string: "https://example.convex.cloud")!,
      session: ConvexClientTesting.makeSession { _ in
        let body = """
          {
            "status": "success",
            "value": {
              "bootstrapVersion": 1,
              "serverTime": 1,
              "service": "private-email-api",
              "status": "degraded"
            }
          }
          """.data(using: .utf8)!
        let response = HTTPURLResponse(
          url: URL(string: "https://example.convex.cloud/api/action")!,
          statusCode: 200,
          httpVersion: nil,
          headerFields: nil
        )!
        return (response, body)
      }
    )
    let service = ConvexBackendHealthService(client: client)

    do {
      _ = try await service.health()
      Issue.record("Expected domain health error")
    } catch let error as BackendHealthError {
      #expect(error == .unsuccessfulStatus("degraded"))
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }
}
