import XCTest

@testable import unwired_mail

final class ConvexClientTests: XCTestCase {
  func testMissingConvexURLReportsSetupError() async {
    let client = ConvexClient(convexURL: nil)

    do {
      _ = try await client.health()
      XCTFail("Expected missing Convex URL error")
    } catch let error as ConvexClientError {
      XCTAssertEqual(error, .missingConvexURL)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testHttpErrorSurfacesTransportFailure() async {
    let client = ConvexClient(
      convexURL: URL(string: "https://example.convex.cloud")!,
      session: ConvexClientTesting.makeSession { _ in
        let response = HTTPURLResponse(
          url: URL(string: "https://example.convex.cloud/api/action")!,
          statusCode: 503,
          httpVersion: nil,
          headerFields: nil
        )!
        return (response, Data())
      }
    )

    do {
      _ = try await client.health()
      XCTFail("Expected HTTP transport error")
    } catch let error as ConvexClientError {
      XCTAssertEqual(error, .httpError(statusCode: 503))
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testConvexFailureSurfacesTransportFailure() async {
    let client = ConvexClient(
      convexURL: URL(string: "https://example.convex.cloud")!,
      session: ConvexClientTesting.makeSession { _ in
        let body = """
          {
            "status": "failure",
            "value": {
              "bootstrapVersion": 1,
              "serverTime": 1,
              "service": "private-email-api",
              "status": "ok"
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

    do {
      _ = try await client.health()
      XCTFail("Expected Convex failure error")
    } catch let error as ConvexClientError {
      XCTAssertEqual(error, .convexFailure(status: "failure"))
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testHealthDecodesSharedContractFixture() async throws {
    // Must match packages/contracts/fixtures/health.response.json
    let fixtureEnvelope = """
      {
        "status": "success",
        "value": {
          "bootstrapVersion": 1,
          "serverTime": 1781200000000,
          "service": "private-email-api",
          "status": "ok"
        }
      }
      """.data(using: .utf8)!

    let client = ConvexClient(
      convexURL: URL(string: "https://example.convex.cloud")!,
      session: ConvexClientTesting.makeSession { request in
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/action")
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: nil,
          headerFields: nil
        )!
        return (response, fixtureEnvelope)
      }
    )

    let response = try await client.health()
    XCTAssertEqual(
      response,
      HealthResponse(
        bootstrapVersion: 1,
        serverTime: 1_781_200_000_000,
        service: "private-email-api",
        status: "ok"
      )
    )
  }

  func testConnectProductAccountSendsAuthenticatedMutation() async throws {
    let fixtureEnvelope = """
      {
        "status": "success",
        "value": {
          "accountCreated": true,
          "deviceRegistered": true,
          "productAccountId": "productAccountFixtureId",
          "trustedDeviceId": "trustedDeviceFixtureId"
        }
      }
      """.data(using: .utf8)!

    let client = ConvexClient(
      convexURL: URL(string: "https://example.convex.cloud")!,
      session: ConvexClientTesting.makeSession { request in
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/mutation")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer apple-token")
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: nil,
          headerFields: nil
        )!
        return (response, fixtureEnvelope)
      }
    )

    let response = try await client.connectProductAccount(
      identityToken: "apple-token",
      deviceIdentifier: "device-001",
      platform: "ios"
    )

    XCTAssertEqual(response, ProductAccountConnectResponse.preview)
  }
}
