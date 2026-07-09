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
      XCTAssertEqual(error, .convexFailure(status: "failure", message: nil))
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
        return (convexClientTestResponse(for: request), fixtureEnvelope)
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
          "productSyncMaterialInitialized": false,
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
        return (convexClientTestResponse(for: request), fixtureEnvelope)
      }
    )

    let response = try await client.connectProductAccount(
      identityToken: "apple-token",
      deviceIdentifier: "device-001",
      platform: "ios"
    )

    XCTAssertEqual(response, ProductAccountConnectResponse.preview)
  }

  func testConnectGmailProviderSendsOnlyMetadataToBackend() async throws {
    let fixtureEnvelope = """
      {
        "status": "success",
        "value": {
          "connectedAt": 1781200000000,
          "emailAddress": "user@example.com",
          "lastVerifiedAt": 1781200000000,
          "provider": "gmail",
          "providerAccountIdentifier": "gmail-user-001",
          "trustedDeviceId": "trustedDeviceFixtureId",
          "updatedAt": 1781200000000
        }
      }
      """.data(using: .utf8)!

    let client = ConvexClient(
      convexURL: URL(string: "https://example.convex.cloud")!,
      session: ConvexClientTesting.makeSession { request in
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/mutation")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer apple-token")
        let requestBody = try Self.requestBody(from: request)
        let requestJSON = try XCTUnwrap(
          JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
        )
        XCTAssertEqual(requestJSON["path"] as? String, "productAccount:connectGmailProvider")
        let args = try XCTUnwrap(requestJSON["args"] as? [String: Any])
        XCTAssertEqual(args["emailAddress"] as? String, "user@example.com")
        XCTAssertEqual(args["providerAccountIdentifier"] as? String, "gmail-user-001")
        XCTAssertEqual(args["trustedDeviceId"] as? String, "trustedDeviceFixtureId")
        XCTAssertNil(args["accessToken"])
        XCTAssertNil(args["refreshToken"])
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: nil,
          headerFields: nil
        )!
        return (response, fixtureEnvelope)
      }
    )

    let response = try await client.connectGmailProvider(
      identityToken: "apple-token",
      trustedDeviceId: "trustedDeviceFixtureId",
      emailAddress: "user@example.com",
      providerAccountIdentifier: "gmail-user-001"
    )

    XCTAssertEqual(response.emailAddress, "user@example.com")
    XCTAssertEqual(response.provider, "gmail")
  }

  func testGetGmailProviderConnectionSendsAuthenticatedQuery() async throws {
    let fixtureEnvelope = """
      {
        "status": "success",
        "value": {
          "connectedAt": 1781200000000,
          "emailAddress": "user@example.com",
          "lastVerifiedAt": 1781200000000,
          "provider": "gmail",
          "providerAccountIdentifier": "gmail-user-001",
          "trustedDeviceId": "trustedDeviceFixtureId",
          "updatedAt": 1781200000000
        }
      }
      """.data(using: .utf8)!

    let client = ConvexClient(
      convexURL: URL(string: "https://example.convex.cloud")!,
      session: ConvexClientTesting.makeSession { request in
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/query")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer apple-token")
        let requestBody = try Self.requestBody(from: request)
        let requestJSON = try XCTUnwrap(
          JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
        )
        XCTAssertEqual(requestJSON["path"] as? String, "productAccount:getGmailProviderConnection")
        let args = try XCTUnwrap(requestJSON["args"] as? [String: Any])
        XCTAssertEqual(args["trustedDeviceId"] as? String, "trustedDeviceFixtureId")
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: nil,
          headerFields: nil
        )!
        return (response, fixtureEnvelope)
      }
    )

    let response = try await client.getGmailProviderConnection(
      identityToken: "apple-token",
      trustedDeviceId: "trustedDeviceFixtureId"
    )

    XCTAssertEqual(response?.emailAddress, "user@example.com")
  }

  private static func requestBody(from request: URLRequest) throws -> Data {
    if let body = request.httpBody {
      return body
    }

    let stream = try XCTUnwrap(request.httpBodyStream)
    stream.open()
    defer { stream.close() }

    var data = Data()
    let bufferSize = 1024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    while stream.hasBytesAvailable {
      let bytesRead = stream.read(buffer, maxLength: bufferSize)
      if bytesRead < 0 {
        throw stream.streamError ?? ConvexClientTestError.unreadableRequestBody
      }
      if bytesRead == 0 {
        break
      }
      data.append(buffer, count: bytesRead)
    }

    return data
  }
}

final class ConvexClientProductSyncTests: XCTestCase {
  func testMarkProductSyncMaterialInitializedSendsAuthenticatedMutation() async throws {
    let fixtureEnvelope = """
      {
        "status": "success",
        "value": {
          "productSyncMaterialInitialized": true
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

    let response = try await client.markProductSyncMaterialInitialized(
      identityToken: "apple-token",
      trustedDeviceId: "trustedDeviceFixtureId"
    )

    XCTAssertEqual(
      response,
      ProductSyncMaterialInitializedResponse(productSyncMaterialInitialized: true)
    )
  }

  func testPutEncryptedProductSyncPayloadSendsAuthenticatedMutation() async throws {
    let fixtureEnvelope = """
      {
        "status": "success",
        "value": {
          "encryptedPayload": {
            "algorithm": "AES-GCM-256",
            "ciphertextBase64": "Y2lwaGVydGV4dA",
            "keyVersion": 1,
            "nonceBase64": "bm9uY2U",
            "schemaVersion": 1,
            "tagBase64": "dGFn"
          },
          "payloadIdentifier": "payload-001",
          "updatedAt": 1781200000000
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

    let response = try await client.putEncryptedProductSyncPayload(
      identityToken: "apple-token",
      payloadIdentifier: "payload-001",
      encryptedPayload: ProductSyncEncryptedPayload(
        algorithm: "AES-GCM-256",
        ciphertextBase64: "Y2lwaGVydGV4dA",
        keyVersion: 1,
        nonceBase64: "bm9uY2U",
        schemaVersion: 1,
        tagBase64: "dGFn"
      ),
      trustedDeviceId: "trustedDeviceFixtureId"
    )

    XCTAssertEqual(response.payloadIdentifier, "payload-001")
  }

  func testListEncryptedProductSyncPayloadsSendsAuthenticatedQuery() async throws {
    let firstPageEnvelope = """
      {
        "status": "success",
        "value": {
          "continueCursor": "next-page",
          "isDone": false,
          "page": [
            {
              "encryptedPayload": {
                "algorithm": "AES-GCM-256",
                "ciphertextBase64": "Y2lwaGVydGV4dA",
                "keyVersion": 1,
                "nonceBase64": "bm9uY2U",
                "schemaVersion": 1,
                "tagBase64": "dGFn"
              },
              "payloadIdentifier": "payload-001",
              "updatedAt": 1781200000000
            }
          ]
        }
      }
      """.data(using: .utf8)!
    let secondPageEnvelope = """
      {
        "status": "success",
        "value": {
          "continueCursor": "",
          "isDone": true,
          "page": [
            {
              "encryptedPayload": {
                "algorithm": "AES-GCM-256",
                "ciphertextBase64": "Y2lwaGVydGV4dA",
                "keyVersion": 1,
                "nonceBase64": "bm9uY2U",
                "schemaVersion": 1,
                "tagBase64": "dGFn"
              },
              "payloadIdentifier": "payload-002",
              "updatedAt": 1781200000001
            }
          ]
        }
      }
      """.data(using: .utf8)!
    var requestCount = 0

    let client = ConvexClient(
      convexURL: URL(string: "https://example.convex.cloud")!,
      session: ConvexClientTesting.makeSession { request in
        requestCount += 1
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/query")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer apple-token")
        let requestBody = try Self.requestBody(from: request)
        let requestJSON = try XCTUnwrap(
          JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
        )
        let args = try XCTUnwrap(requestJSON["args"] as? [String: Any])
        let paginationOpts = try XCTUnwrap(args["paginationOpts"] as? [String: Any])
        XCTAssertEqual(paginationOpts["numItems"] as? Int, 100)
        if requestCount == 1 {
          XCTAssertTrue(paginationOpts["cursor"] is NSNull)
        } else {
          XCTAssertEqual(paginationOpts["cursor"] as? String, "next-page")
        }
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: nil,
          headerFields: nil
        )!
        return (response, requestCount == 1 ? firstPageEnvelope : secondPageEnvelope)
      }
    )

    let response = try await client.listEncryptedProductSyncPayloads(
      identityToken: "apple-token"
    )

    XCTAssertEqual(response.map(\.payloadIdentifier), ["payload-001", "payload-002"])
    XCTAssertEqual(requestCount, 2)
  }

  func testGetEncryptedProductSyncPayloadSendsAuthenticatedQuery() async throws {
    let fixtureEnvelope = """
      {
        "status": "success",
        "value": {
          "encryptedPayload": {
            "algorithm": "AES-GCM-256",
            "ciphertextBase64": "Y2lwaGVydGV4dA",
            "keyVersion": 1,
            "nonceBase64": "bm9uY2U",
            "schemaVersion": 1,
            "tagBase64": "dGFn"
          },
          "payloadIdentifier": "custom-category-primary",
          "updatedAt": 1781200000000
        }
      }
      """.data(using: .utf8)!

    let client = ConvexClient(
      convexURL: URL(string: "https://example.convex.cloud")!,
      session: ConvexClientTesting.makeSession { request in
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/query")
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

    let response = try await client.getEncryptedProductSyncPayload(
      identityToken: "apple-token",
      payloadIdentifier: "custom-category-primary"
    )

    XCTAssertEqual(response?.payloadIdentifier, "custom-category-primary")
  }

  func testGetEncryptedProductSyncPayloadDecodesMissingPayload() async throws {
    let fixtureEnvelope = """
      {
        "status": "success",
        "value": null
      }
      """.data(using: .utf8)!

    let client = ConvexClient(
      convexURL: URL(string: "https://example.convex.cloud")!,
      session: ConvexClientTesting.makeSession { request in
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: nil,
          headerFields: nil
        )!
        return (response, fixtureEnvelope)
      }
    )

    let response = try await client.getEncryptedProductSyncPayload(
      identityToken: "apple-token",
      payloadIdentifier: "custom-category-primary"
    )

    XCTAssertNil(response)
  }

  func testConvexErrorEnvelopeSurfacesBackendMessage() async {
    let fixtureEnvelope = """
      {
        "status": "error",
        "errorMessage": "Authentication required"
      }
      """.data(using: .utf8)!

    let client = ConvexClient(
      convexURL: URL(string: "https://example.convex.cloud")!,
      session: ConvexClientTesting.makeSession { request in
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: nil,
          headerFields: nil
        )!
        return (response, fixtureEnvelope)
      }
    )

    do {
      _ = try await client.connectProductAccount(
        identityToken: "apple-token",
        deviceIdentifier: "device-001",
        platform: "ios"
      )
      XCTFail("Expected Convex error envelope")
    } catch let error as ConvexClientError {
      XCTAssertEqual(
        error,
        .convexFailure(status: "error", message: "Authentication required")
      )
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  private static func requestBody(from request: URLRequest) throws -> Data {
    if let body = request.httpBody {
      return body
    }

    let stream = try XCTUnwrap(request.httpBodyStream)
    stream.open()
    defer { stream.close() }

    var data = Data()
    let bufferSize = 1024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    while stream.hasBytesAvailable {
      let bytesRead = stream.read(buffer, maxLength: bufferSize)
      if bytesRead < 0 {
        throw stream.streamError ?? ConvexClientTestError.unreadableRequestBody
      }
      if bytesRead == 0 {
        break
      }
      data.append(buffer, count: bytesRead)
    }

    return data
  }
}

private enum ConvexClientTestError: Error {
  case unreadableRequestBody
}

private func convexClientTestResponse(for request: URLRequest) -> HTTPURLResponse {
  HTTPURLResponse(
    url: request.url!,
    statusCode: 200,
    httpVersion: nil,
    headerFields: nil
  )!
}
