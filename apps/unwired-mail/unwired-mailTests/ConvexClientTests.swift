import XCTest

@testable import unwired_mail

// swiftlint:disable file_length function_body_length non_optional_string_data_conversion type_body_length

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
      deviceName: "Jans iPhone",
      platform: "ios"
    )

    XCTAssertEqual(response, ProductAccountConnectResponse.preview)
  }

  func testDeleteProductAccountSendsRecentAuthorizationToAuthenticatedAction() async throws {
    let fixtureEnvelope = """
      {
        "status": "success",
        "value": { "deleted": true }
      }
      """.data(using: .utf8)!
    let client = ConvexClient(
      convexURL: URL(string: "https://example.convex.cloud")!,
      session: ConvexClientTesting.makeSession { request in
        XCTAssertEqual(request.url?.path, "/api/action")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer apple-token")
        let requestJSON = try XCTUnwrap(
          JSONSerialization.jsonObject(with: Self.requestBody(from: request)) as? [String: Any]
        )
        XCTAssertEqual(
          requestJSON["path"] as? String,
          "productAccountDeletion:deleteProductAccount"
        )
        let args = try XCTUnwrap(requestJSON["args"] as? [String: Any])
        XCTAssertEqual(args["authorizationCode"] as? String, "recent-authorization-code")
        XCTAssertEqual(args["trustedDeviceId"] as? String, "trustedDeviceFixtureId")
        return (convexClientTestResponse(for: request), fixtureEnvelope)
      }
    )

    let response = try await client.deleteProductAccount(
      authorizationCode: "recent-authorization-code",
      identityToken: "apple-token",
      trustedDeviceId: "trustedDeviceFixtureId"
    )

    XCTAssertEqual(response, ProductAccountDeletionResponse(deleted: true))
  }

  func testListTrustedDevicesSendsAuthenticatedQuery() async throws {
    let fixtureEnvelope = """
      {
        "status": "success",
        "value": [{
          "displayName": "Jans iPhone",
          "id": "trustedDeviceFixtureId",
          "lastSeenAt": 1781200000000,
          "platform": "ios",
          "registeredAt": 1781100000000
        }]
      }
      """.data(using: .utf8)!

    let client = ConvexClient(
      convexURL: URL(string: "https://example.convex.cloud")!,
      session: ConvexClientTesting.makeSession { request in
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/query")
        XCTAssertEqual(
          request.value(forHTTPHeaderField: "Authorization"),
          "Bearer apple-token"
        )
        return (convexClientTestResponse(for: request), fixtureEnvelope)
      }
    )

    let devices = try await client.listTrustedDevices(
      identityToken: "apple-token",
      trustedDeviceId: "trustedDeviceFixtureId"
    )

    XCTAssertEqual(devices.map(\.displayName), ["Jans iPhone"])
  }

  func testRenameTrustedDeviceSendsAuthenticatedMutation() async throws {
    let fixtureEnvelope = """
      {
        "status": "success",
        "value": {
          "displayName": "Desk Mac",
          "id": "trustedDeviceFixtureId",
          "lastSeenAt": 1781200000000,
          "platform": "macos",
          "registeredAt": 1781100000000
        }
      }
      """.data(using: .utf8)!

    let client = ConvexClient(
      convexURL: URL(string: "https://example.convex.cloud")!,
      session: ConvexClientTesting.makeSession { request in
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/mutation")
        XCTAssertEqual(
          request.value(forHTTPHeaderField: "Authorization"),
          "Bearer apple-token"
        )
        return (convexClientTestResponse(for: request), fixtureEnvelope)
      }
    )

    let device = try await client.renameTrustedDevice(
      displayName: "Desk Mac",
      identityToken: "apple-token",
      trustedDeviceId: "currentDeviceFixtureId",
      trustedDeviceToRenameId: "trustedDeviceFixtureId"
    )

    XCTAssertEqual(device.displayName, "Desk Mac")
  }

  func testUnregisterTrustedDeviceBindsTheCurrentDeviceIdentifier() async throws {
    let fixtureEnvelope = """
      {
        "status": "success",
        "value": { "registered": false }
      }
      """.data(using: .utf8)!

    let client = ConvexClient(
      convexURL: URL(string: "https://example.convex.cloud")!,
      session: ConvexClientTesting.makeSession { request in
        let requestJSON = try XCTUnwrap(
          JSONSerialization.jsonObject(with: Self.requestBody(from: request))
            as? [String: Any]
        )
        XCTAssertEqual(
          requestJSON["path"] as? String,
          "productAccount:unregisterTrustedDevice"
        )
        let args = try XCTUnwrap(requestJSON["args"] as? [String: Any])
        XCTAssertEqual(args["deviceIdentifier"] as? String, "device-001")
        XCTAssertEqual(args["trustedDeviceId"] as? String, "trustedDeviceFixtureId")
        return (convexClientTestResponse(for: request), fixtureEnvelope)
      }
    )

    let response = try await client.unregisterTrustedDevice(
      deviceIdentifier: "device-001",
      identityToken: "apple-token",
      trustedDeviceId: "trustedDeviceFixtureId"
    )

    XCTAssertFalse(response.registered)
  }

  func testRegisterGmailConnectionSendsOnlyOpaqueOperationalData() async throws {
    let fixtureEnvelope = """
      {
        "status": "success",
        "value": {
          "connectedAt": 1781200000000,
          "lastVerifiedAt": 1781200000000,
          "opaqueConnectionId": "opaque-connection-001",
          "trustedDeviceId": "trustedDeviceFixtureId",
          "updatedAt": 1781200000000
        }
      }
      """.data(using: .utf8)!

    let client = ConvexClient(
      convexURL: URL(string: "https://example.convex.cloud")!,
      session: ConvexClientTesting.makeSession { request in
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/action")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer apple-token")
        let requestBody = try Self.requestBody(from: request)
        let requestJSON = try XCTUnwrap(
          JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
        )
        XCTAssertEqual(requestJSON["path"] as? String, "pushRelay:registerGmailConnection")
        let args = try XCTUnwrap(requestJSON["args"] as? [String: Any])
        XCTAssertEqual(args["gmailIdentityToken"] as? String, "gmail-identity-token")
        XCTAssertEqual(args["opaqueConnectionId"] as? String, "opaque-connection-001")
        XCTAssertEqual(args["trustedDeviceId"] as? String, "trustedDeviceFixtureId")
        XCTAssertNil(args["emailAddress"])
        XCTAssertNil(args["providerAccountIdentifier"])
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

    let response = try await client.registerGmailConnection(
      gmailIdentityToken: "gmail-identity-token",
      identityToken: "apple-token",
      opaqueConnectionId: "opaque-connection-001",
      trustedDeviceId: "trustedDeviceFixtureId"
    )

    XCTAssertEqual(response.opaqueConnectionId, "opaque-connection-001")
  }

  func testRemoveGmailConnectionSendsOpaqueScopedMutation() async throws {
    let fixtureEnvelope = """
      {"status":"success","value":{"hasRemainingGmailConnections":false,"removed":true}}
      """.data(using: .utf8)!
    let client = ConvexClient(
      convexURL: URL(string: "https://example.convex.cloud")!,
      session: ConvexClientTesting.makeSession { request in
        let requestJSON = try XCTUnwrap(
          JSONSerialization.jsonObject(with: Self.requestBody(from: request)) as? [String: Any]
        )
        XCTAssertEqual(
          requestJSON["path"] as? String, "pushRelay:removeGmailConnection")
        let args = try XCTUnwrap(requestJSON["args"] as? [String: Any])
        XCTAssertEqual(args["opaqueConnectionId"] as? String, "opaque-connection-001")
        XCTAssertNil(args["providerAccountIdentifier"])
        XCTAssertEqual(args["trustedDeviceId"] as? String, "trustedDeviceFixtureId")
        XCTAssertEqual(request.url?.path, "/api/mutation")
        return (convexClientTestResponse(for: request), fixtureEnvelope)
      }
    )

    let hasRemainingGmailConnections = try await client.removeGmailConnection(
      identityToken: "apple-token",
      opaqueConnectionId: "opaque-connection-001",
      trustedDeviceId: "trustedDeviceFixtureId"
    )

    XCTAssertFalse(hasRemainingGmailConnections)
  }

  func testUnregisterDevicePushSendsAuthenticatedMutation() async throws {
    let fixtureEnvelope = #"{"status":"success","value":{"registered":false}}"#.data(
      using: .utf8
    )!
    let client = ConvexClient(
      convexURL: URL(string: "https://example.convex.cloud")!,
      session: ConvexClientTesting.makeSession { request in
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/mutation")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer apple-token")
        let requestJSON = try XCTUnwrap(
          JSONSerialization.jsonObject(with: Self.requestBody(from: request)) as? [String: Any]
        )
        XCTAssertEqual(requestJSON["path"] as? String, "pushRelay:unregisterDevice")
        let args = try XCTUnwrap(requestJSON["args"] as? [String: Any])
        XCTAssertEqual(args["trustedDeviceId"] as? String, "trustedDeviceFixtureId")
        return (convexClientTestResponse(for: request), fixtureEnvelope)
      }
    )

    let response = try await client.unregisterDevicePush(
      identityToken: "apple-token",
      trustedDeviceId: "trustedDeviceFixtureId"
    )

    XCTAssertFalse(response.registered)
  }

  func testVerifyGmailPushWatchSendsHistoryProofWithoutProviderTokens() async throws {
    let fixtureEnvelope =
      #"{"status":"success","value":{"routeId":"route-001","verified":true}}"#.data(
        using: .utf8
      )!
    let client = ConvexClient(
      convexURL: URL(string: "https://example.convex.cloud")!,
      session: ConvexClientTesting.makeSession { request in
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/action")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer apple-token")
        let requestJSON = try XCTUnwrap(
          JSONSerialization.jsonObject(with: Self.requestBody(from: request)) as? [String: Any]
        )
        XCTAssertEqual(requestJSON["path"] as? String, "pushRelay:verifyGmailWatch")
        let args = try XCTUnwrap(requestJSON["args"] as? [String: Any])
        XCTAssertEqual(args["gmailIdentityToken"] as? String, "gmail-identity-token")
        XCTAssertEqual(args["historyId"] as? String, "history-123")
        XCTAssertEqual(args["opaqueConnectionId"] as? String, "opaque-connection-001")
        XCTAssertEqual(args["trustedDeviceId"] as? String, "trustedDeviceFixtureId")
        XCTAssertNil(args["accessToken"])
        XCTAssertNil(args["refreshToken"])
        return (convexClientTestResponse(for: request), fixtureEnvelope)
      }
    )

    let response = try await client.verifyGmailPushWatch(
      gmailIdentityToken: "gmail-identity-token",
      historyId: "history-123",
      identityToken: "apple-token",
      opaqueConnectionId: "opaque-connection-001",
      trustedDeviceId: "trustedDeviceFixtureId"
    )

    XCTAssertTrue(response.verified)
    XCTAssertEqual(response.routeId, "route-001")
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

  func testReplaceRecoveryMaterialUsesDedicatedRecentAuthenticationEndpoint()
    async throws
  {
    let fixtureResponse = """
      {
        "encryptedPayload": {
          "algorithm": "AES-GCM-256",
          "ciphertextBase64": "Y2lwaGVydGV4dA",
          "keyVersion": 1,
          "nonceBase64": "bm9uY2U",
          "schemaVersion": 1,
          "tagBase64": "dGFn"
        },
        "payloadIdentifier": "product-account-recovery-v1",
        "updatedAt": 1781200000000
      }
      """.data(using: .utf8)!

    let client = ConvexClient(
      convexURL: URL(string: "https://example.convex.cloud")!,
      convexSiteURL: URL(string: "https://example.convex.site")!,
      session: ConvexClientTesting.makeSession { request in
        XCTAssertEqual(request.url?.host(), "example.convex.site")
        XCTAssertEqual(request.url?.path, "/product-sync/recovery-material")
        XCTAssertEqual(
          request.value(forHTTPHeaderField: "Authorization"),
          "Bearer fresh-apple-token"
        )
        let requestJSON = try XCTUnwrap(
          JSONSerialization.jsonObject(with: Self.requestBody(from: request))
            as? [String: Any]
        )
        XCTAssertNil(requestJSON["payloadIdentifier"])
        XCTAssertEqual(
          requestJSON["trustedDeviceId"] as? String,
          "trustedDeviceFixtureId"
        )
        return (convexClientTestResponse(for: request), fixtureResponse)
      }
    )

    let response = try await client.replaceRecoveryMaterialIfUnchanged(
      identityToken: "fresh-apple-token",
      encryptedPayload: ProductSyncEncryptedPayload(
        algorithm: "AES-GCM-256",
        ciphertextBase64: "Y2lwaGVydGV4dA",
        keyVersion: 1,
        nonceBase64: "bm9uY2U",
        schemaVersion: 1,
        tagBase64: "dGFn"
      ),
      trustedDeviceId: "trustedDeviceFixtureId",
      expectedUpdatedAt: nil
    )

    XCTAssertEqual(response.payloadIdentifier, "product-account-recovery-v1")
  }

  func testCustomConvexURLDerivesMatchingSiteURL() async {
    let client = ConvexClient(
      convexURL: URL(string: "https://custom.convex.cloud")!,
      session: ConvexClientTesting.makeSession { request in
        XCTAssertEqual(request.url?.host(), "custom.convex.site")
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 401,
          httpVersion: nil,
          headerFields: nil
        )!
        return (response, Data("Recent authentication required".utf8))
      }
    )

    do {
      _ = try await client.replaceRecoveryMaterialIfUnchanged(
        identityToken: "stale-token",
        encryptedPayload: ProductSyncEncryptedPayload(
          algorithm: "AES-GCM-256",
          ciphertextBase64: "Y2lwaGVydGV4dA",
          keyVersion: 1,
          nonceBase64: "bm9uY2U",
          schemaVersion: 1,
          tagBase64: "dGFn"
        ),
        trustedDeviceId: "trustedDeviceFixtureId",
        expectedUpdatedAt: nil
      )
      XCTFail("Expected HTTP action error")
    } catch let error as ConvexClientError {
      XCTAssertEqual(
        error,
        .httpActionError(statusCode: 401, message: "Recent authentication required")
      )
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testRecoveryReplacementSurfacesRevokedDeviceCode() async {
    let client = ConvexClient(
      convexURL: URL(string: "https://example.convex.cloud")!,
      convexSiteURL: URL(string: "https://example.convex.site")!,
      session: ConvexClientTesting.makeSession { request in
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 403,
          httpVersion: nil,
          headerFields: nil
        )!
        return (response, Data(#"{"code":"TRUSTED_DEVICE_REVOKED"}"#.utf8))
      }
    )

    do {
      _ = try await client.replaceRecoveryMaterialIfUnchanged(
        identityToken: "fresh-apple-token",
        encryptedPayload: ProductSyncEncryptedPayload(
          algorithm: "AES-GCM-256",
          ciphertextBase64: "Y2lwaGVydGV4dA",
          keyVersion: 1,
          nonceBase64: "bm9uY2U",
          schemaVersion: 1,
          tagBase64: "dGFn"
        ),
        trustedDeviceId: "trustedDeviceFixtureId",
        expectedUpdatedAt: nil
      )
      XCTFail("Expected trusted-device revocation")
    } catch let error as ConvexClientError {
      XCTAssertEqual(
        error,
        .convexApplicationFailure(
          status: "error",
          code: "TRUSTED_DEVICE_REVOKED",
          message: nil
        )
      )
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testListEncryptedProductSyncPayloadsSendsAuthenticatedPrefixedQuery() async throws {
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
        XCTAssertEqual(args["trustedDeviceId"] as? String, "trusted-device-001")
        XCTAssertEqual(
          args["payloadIdentifierPrefix"] as? String,
          "message-category-learning-signal:"
        )
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
      identityToken: "apple-token",
      payloadIdentifierPrefix: "message-category-learning-signal:",
      trustedDeviceId: "trusted-device-001"
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
        let requestBody = try Self.requestBody(from: request)
        let requestJSON = try XCTUnwrap(
          JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
        )
        let args = try XCTUnwrap(requestJSON["args"] as? [String: Any])
        XCTAssertEqual(args["trustedDeviceId"] as? String, "trusted-device-001")
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
      payloadIdentifier: "custom-category-primary",
      trustedDeviceId: "trusted-device-001"
    )

    XCTAssertEqual(response?.payloadIdentifier, "custom-category-primary")
  }

  func testGetEncryptedProductSyncPayloadsSendsTargetedQuery() async throws {
    let fixtureEnvelope = """
      {
        "status": "success",
        "value": []
      }
      """.data(using: .utf8)!
    let client = ConvexClient(
      convexURL: URL(string: "https://example.convex.cloud")!,
      session: ConvexClientTesting.makeSession { request in
        let requestBody = try Self.requestBody(from: request)
        let requestJSON = try XCTUnwrap(
          JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
        )
        XCTAssertEqual(
          requestJSON["path"] as? String,
          "productSync:getEncryptedPayloadsForTrustedDevice"
        )
        let args = try XCTUnwrap(requestJSON["args"] as? [String: Any])
        XCTAssertEqual(args["payloadIdentifiers"] as? [String], ["payload-001"])
        XCTAssertEqual(args["trustedDeviceId"] as? String, "trusted-device-001")
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: nil,
          headerFields: nil
        )!
        return (response, fixtureEnvelope)
      }
    )

    let response = try await client.getEncryptedProductSyncPayloads(
      identityToken: "apple-token",
      payloadIdentifiers: ["payload-001"],
      trustedDeviceId: "trusted-device-001"
    )

    XCTAssertTrue(response.isEmpty)
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
      payloadIdentifier: "custom-category-primary",
      trustedDeviceId: "trusted-device-001"
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
        deviceName: "Jans iPhone",
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

  func testConvexApplicationErrorEnvelopeSurfacesStableCode() async {
    let fixtureEnvelope = """
      {
        "status": "error",
        "errorMessage": "Server Error",
        "errorData": { "code": "TRUSTED_DEVICE_REVOKED" }
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
        deviceName: "Jans iPhone",
        platform: "ios"
      )
      XCTFail("Expected Convex application error envelope")
    } catch let error as ConvexClientError {
      XCTAssertEqual(
        error,
        .convexApplicationFailure(
          status: "error",
          code: "TRUSTED_DEVICE_REVOKED",
          message: "Server Error"
        )
      )
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testProductAccountServiceTranslatesRevocationWhileMarkingSyncInitialized() async {
    let service = ConvexProductAccountService(client: revokedDeviceClient())

    do {
      _ = try await service.markProductSyncMaterialInitialized(
        identityToken: "apple-token",
        trustedDeviceId: "trusted-device-001"
      )
      XCTFail("Expected trusted-device revocation")
    } catch let error as ProductAccountServiceError {
      XCTAssertEqual(error, .trustedDeviceRevoked)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testProductAccountServiceTranslatesRevocationWhileLoadingRecoveryMaterial() async {
    let service = ConvexProductAccountService(client: revokedDeviceClient())

    do {
      _ = try await service.productSyncRecoveryMaterial(
        identityToken: "apple-token",
        trustedDeviceId: "trusted-device-001"
      )
      XCTFail("Expected trusted-device revocation")
    } catch let error as ProductAccountServiceError {
      XCTAssertEqual(error, .trustedDeviceRevoked)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  private func revokedDeviceClient() -> ConvexClient {
    let fixtureEnvelope = """
      {
        "status": "error",
        "errorMessage": "Server Error",
        "errorData": { "code": "TRUSTED_DEVICE_REVOKED" }
      }
      """.data(using: .utf8)!

    return ConvexClient(
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
  }

  func testConvexApplicationErrorEnvelopeFallsBackForEmptyMessage() {
    let error = ConvexClientError.convexApplicationFailure(
      status: "error",
      code: "PRODUCT_ACCOUNT_DELETED",
      message: ""
    )

    XCTAssertEqual(error.localizedDescription, "The backend rejected the request.")
  }

  func testProductAccountServiceReturnsIncompleteDeletionWithoutRetrying() async throws {
    let fixtureEnvelope = #"{"status":"success","value":{"deleted":false}}"#.data(
      using: .utf8
    )!
    var requestCount = 0
    let service = ConvexProductAccountService(
      client: ConvexClient(
        convexURL: URL(string: "https://example.convex.cloud")!,
        session: ConvexClientTesting.makeSession { request in
          requestCount += 1
          return (convexClientTestResponse(for: request), fixtureEnvelope)
        }
      )
    )

    let response = try await service.deleteProductAccount(
      authorizationCode: "recent-authorization-code",
      identityToken: "apple-token",
      trustedDeviceId: "trusted-device-001"
    )

    XCTAssertFalse(response.deleted)
    XCTAssertEqual(requestCount, 1)
  }

  func testProductAccountServiceMapsDeletedAccountDeletionToSuccess() async throws {
    let fixtureEnvelope = """
      {
        "status": "error",
        "errorMessage": "This Product Account was deleted.",
        "errorData": { "code": "PRODUCT_ACCOUNT_DELETED" }
      }
      """.data(using: .utf8)!
    let service = ConvexProductAccountService(
      client: ConvexClient(
        convexURL: URL(string: "https://example.convex.cloud")!,
        session: ConvexClientTesting.makeSession { request in
          (convexClientTestResponse(for: request), fixtureEnvelope)
        }
      )
    )

    let response = try await service.deleteProductAccount(
      authorizationCode: "recent-authorization-code",
      identityToken: "apple-token",
      trustedDeviceId: "trusted-device-001"
    )

    XCTAssertTrue(response.deleted)
  }

  func testProductAccountServiceMapsDeletedTrustedDeviceUnregistration() async {
    let fixtureEnvelope = """
      {
        "status": "error",
        "errorMessage": "This Product Account was deleted.",
        "errorData": { "code": "PRODUCT_ACCOUNT_DELETED" }
      }
      """.data(using: .utf8)!
    let service = ConvexProductAccountService(
      client: ConvexClient(
        convexURL: URL(string: "https://example.convex.cloud")!,
        session: ConvexClientTesting.makeSession { request in
          (convexClientTestResponse(for: request), fixtureEnvelope)
        }
      )
    )

    do {
      _ = try await service.unregisterTrustedDevice(
        identityToken: "apple-token",
        trustedDeviceId: "trusted-device-001"
      )
      XCTFail("Expected deleted Product Account error")
    } catch {
      XCTAssertEqual(error as? ProductAccountServiceError, .productAccountDeleted)
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
