import Foundation
import Testing

@testable import unwired_mail

// swiftlint:disable file_length function_body_length non_optional_string_data_conversion type_body_length

@Suite(.serialized)
final class ConvexClientTests {
  @Test
  func testMissingConvexURLReportsSetupError() async {
    let client = ConvexClient(convexURL: nil)

    do {
      _ = try await client.health()
      Issue.record("Expected missing Convex URL error")
    } catch let error as ConvexClientError {
      #expect(error == .missingConvexURL)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
  func testAuthenticatedRequestRejectsInsecureConvexURLBeforeTransport() async {
    let client = ConvexClient(
      convexURL: URL(string: "http://example.convex.cloud")!,
      session: ConvexClientTesting.makeSession { _ in
        Issue.record("Transport must not receive an authenticated insecure request")
        throw URLError(.badURL)
      }
    )

    do {
      _ = try await client.listTrustedDevices(
        identityToken: "apple-token",
        trustedDeviceId: "trusted-device-001"
      )
      Issue.record("Expected insecure Convex URL error")
    } catch let error as ConvexClientError {
      #expect(error == .insecureConvexURL)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
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
      Issue.record("Expected HTTP transport error")
    } catch let error as ConvexClientError {
      #expect(error == .httpError(statusCode: 503))
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
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
      Issue.record("Expected Convex failure error")
    } catch let error as ConvexClientError {
      #expect(error == .convexFailure(status: "failure", message: nil))
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
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
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/action")
        return (convexClientTestResponse(for: request), fixtureEnvelope)
      }
    )

    let response = try await client.health()
    #expect(
      response
        == HealthResponse(
          bootstrapVersion: 1,
          serverTime: 1_781_200_000_000,
          service: "private-email-api",
          status: "ok"
        ))
  }

  @Test
  func testConnectProductAccountSendsAuthenticatedMutation() async throws {
    let fixtureEnvelope = """
      {
        "status": "success",
        "value": {
          "accountCreated": true,
          "deviceRegistered": true,
          "productSyncMaterialInitialized": false,
          "productAccountId": "productAccountFixtureId",
          "trustedDeviceCredential": "trusted-device-credential",
          "trustedDeviceId": "trustedDeviceFixtureId"
        }
      }
      """.data(using: .utf8)!

    let client = ConvexClient(
      convexURL: URL(string: "https://example.convex.cloud")!,
      session: ConvexClientTesting.makeSession { request in
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/mutation")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer apple-token")
        let requestJSON = try requireValue(
          JSONSerialization.jsonObject(with: Self.requestBody(from: request)) as? [String: Any])
        let args = try requireValue(requestJSON["args"] as? [String: Any])
        #expect(args["supportsDeviceCredentials"] as? Bool == true)
        #expect(args["trustedDeviceCredential"] as? String == "existing-credential")
        return (convexClientTestResponse(for: request), fixtureEnvelope)
      }
    )

    let response = try await client.connectProductAccount(
      identityToken: "apple-token",
      deviceIdentifier: "device-001",
      deviceName: "Jans iPhone",
      platform: "ios",
      trustedDeviceCredential: "existing-credential"
    )

    #expect(
      response
        == ProductAccountConnectResponse(
          accountCreated: true,
          deviceRegistered: true,
          productSyncMaterialInitialized: false,
          productAccountId: "productAccountFixtureId",
          trustedDeviceCredential: "trusted-device-credential",
          trustedDeviceId: "trustedDeviceFixtureId"
        ))
  }

  @Test
  func testProductAccountServicePersistsIssuedTrustedDeviceCredential() async throws {
    let fixtureEnvelope = """
      {
        "status": "success",
        "value": {
          "accountCreated": true,
          "deviceRegistered": true,
          "productSyncMaterialInitialized": false,
          "productAccountId": "productAccountFixtureId",
          "trustedDeviceCredential": "trusted-device-credential",
          "trustedDeviceId": "trustedDeviceFixtureId"
        }
      }
      """.data(using: .utf8)!
    let credentialStore = InMemoryTrustedDeviceCredentialStore(
      credentials: ["trustedDeviceFixtureId": "existing-credential"]
    )
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(
      ProductAccountSessionSnapshot(
        appleUserIdentifier: "apple-user-001",
        identityToken: "apple-token",
        productAccountId: "productAccountFixtureId",
        trustedDeviceId: "trustedDeviceFixtureId"
      )
    )
    let client = ConvexClient(
      convexURL: URL(string: "https://example.convex.cloud")!,
      session: ConvexClientTesting.makeSession { request in
        let requestJSON = try requireValue(
          JSONSerialization.jsonObject(with: Self.requestBody(from: request)) as? [String: Any])
        let args = try requireValue(requestJSON["args"] as? [String: Any])
        #expect(args["trustedDeviceCredential"] as? String == "existing-credential")
        return (convexClientTestResponse(for: request), fixtureEnvelope)
      },
      trustedDeviceCredentialStore: credentialStore
    )
    let service = ConvexProductAccountService(
      client: client,
      sessionStore: sessionStore,
      trustedDeviceCredentialStore: credentialStore
    )

    let response = try await service.connect(identityToken: "apple-token")

    #expect(
      try credentialStore.load(trustedDeviceId: response.trustedDeviceId)
        == "trusted-device-credential")
  }

  @Test
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
        #expect(request.url?.path == "/api/action")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer apple-token")
        let requestJSON = try requireValue(
          JSONSerialization.jsonObject(with: Self.requestBody(from: request)) as? [String: Any])
        #expect(requestJSON["path"] as? String == "productAccountDeletion:deleteProductAccount")
        let args = try requireValue(requestJSON["args"] as? [String: Any])
        #expect(args["authorizationCode"] as? String == "recent-authorization-code")
        #expect(args["trustedDeviceId"] as? String == "trustedDeviceFixtureId")
        return (convexClientTestResponse(for: request), fixtureEnvelope)
      }
    )

    let response = try await client.deleteProductAccount(
      authorizationCode: "recent-authorization-code",
      identityToken: "apple-token",
      trustedDeviceId: "trustedDeviceFixtureId"
    )

    #expect(response == ProductAccountDeletionResponse(deleted: true))
  }

  @Test
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

    let credentialStore = InMemoryTrustedDeviceCredentialStore(
      credentials: ["trustedDeviceFixtureId": "trusted-device-credential"]
    )
    let client = ConvexClient(
      convexURL: URL(string: "https://example.convex.cloud")!,
      session: ConvexClientTesting.makeSession { request in
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/query")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer apple-token")
        let requestJSON = try requireValue(
          JSONSerialization.jsonObject(with: Self.requestBody(from: request)) as? [String: Any])
        let args = try requireValue(requestJSON["args"] as? [String: Any])
        #expect(args["trustedDeviceCredential"] as? String == "trusted-device-credential")
        return (convexClientTestResponse(for: request), fixtureEnvelope)
      },
      trustedDeviceCredentialStore: credentialStore
    )

    let devices = try await client.listTrustedDevices(
      identityToken: "apple-token",
      trustedDeviceId: "trustedDeviceFixtureId"
    )

    #expect(devices.map(\.displayName) == ["Jans iPhone"])
  }

  @Test
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
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/mutation")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer apple-token")
        return (convexClientTestResponse(for: request), fixtureEnvelope)
      }
    )

    let device = try await client.renameTrustedDevice(
      displayName: "Desk Mac",
      identityToken: "apple-token",
      trustedDeviceId: "currentDeviceFixtureId",
      trustedDeviceToRenameId: "trustedDeviceFixtureId"
    )

    #expect(device.displayName == "Desk Mac")
  }

  @Test
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
        let requestJSON = try requireValue(
          JSONSerialization.jsonObject(with: Self.requestBody(from: request))
            as? [String: Any])
        #expect(requestJSON["path"] as? String == "productAccount:unregisterTrustedDevice")
        let args = try requireValue(requestJSON["args"] as? [String: Any])
        #expect(args["deviceIdentifier"] as? String == "device-001")
        #expect(args["trustedDeviceId"] as? String == "trustedDeviceFixtureId")
        return (convexClientTestResponse(for: request), fixtureEnvelope)
      }
    )

    let response = try await client.unregisterTrustedDevice(
      deviceIdentifier: "device-001",
      identityToken: "apple-token",
      trustedDeviceId: "trustedDeviceFixtureId"
    )

    #expect(!(response.registered))
  }

  @Test
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
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/action")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer apple-token")
        let requestBody = try Self.requestBody(from: request)
        let requestJSON = try requireValue(
          JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        #expect(requestJSON["path"] as? String == "pushRelay:registerGmailConnection")
        let args = try requireValue(requestJSON["args"] as? [String: Any])
        #expect(args["gmailIdentityToken"] as? String == "gmail-identity-token")
        #expect(args["opaqueConnectionId"] as? String == "opaque-connection-001")
        #expect(args["trustedDeviceId"] as? String == "trustedDeviceFixtureId")
        #expect(args["emailAddress"] == nil)
        #expect(args["providerAccountIdentifier"] == nil)
        #expect(args["accessToken"] == nil)
        #expect(args["refreshToken"] == nil)
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

    #expect(response.opaqueConnectionId == "opaque-connection-001")
  }

  @Test
  func testRemoveGmailConnectionSendsOpaqueScopedMutation() async throws {
    let fixtureEnvelope = """
      {"status":"success","value":{"hasRemainingGmailConnections":false,"removed":true}}
      """.data(using: .utf8)!
    let client = ConvexClient(
      convexURL: URL(string: "https://example.convex.cloud")!,
      session: ConvexClientTesting.makeSession { request in
        let requestJSON = try requireValue(
          JSONSerialization.jsonObject(with: Self.requestBody(from: request)) as? [String: Any])
        #expect(requestJSON["path"] as? String == "pushRelay:removeGmailConnection")
        let args = try requireValue(requestJSON["args"] as? [String: Any])
        #expect(args["opaqueConnectionId"] as? String == "opaque-connection-001")
        #expect(args["providerAccountIdentifier"] == nil)
        #expect(args["trustedDeviceId"] as? String == "trustedDeviceFixtureId")
        #expect(request.url?.path == "/api/mutation")
        return (convexClientTestResponse(for: request), fixtureEnvelope)
      }
    )

    let hasRemainingGmailConnections = try await client.removeGmailConnection(
      identityToken: "apple-token",
      opaqueConnectionId: "opaque-connection-001",
      trustedDeviceId: "trustedDeviceFixtureId"
    )

    #expect(!(hasRemainingGmailConnections))
  }

  @Test
  func testUnregisterDevicePushSendsAuthenticatedMutation() async throws {
    let fixtureEnvelope = #"{"status":"success","value":{"registered":false}}"#.data(
      using: .utf8
    )!
    let client = ConvexClient(
      convexURL: URL(string: "https://example.convex.cloud")!,
      session: ConvexClientTesting.makeSession { request in
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/mutation")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer apple-token")
        let requestJSON = try requireValue(
          JSONSerialization.jsonObject(with: Self.requestBody(from: request)) as? [String: Any])
        #expect(requestJSON["path"] as? String == "pushRelay:unregisterDevice")
        let args = try requireValue(requestJSON["args"] as? [String: Any])
        #expect(args["trustedDeviceId"] as? String == "trustedDeviceFixtureId")
        return (convexClientTestResponse(for: request), fixtureEnvelope)
      }
    )

    let response = try await client.unregisterDevicePush(
      identityToken: "apple-token",
      trustedDeviceId: "trustedDeviceFixtureId"
    )

    #expect(!(response.registered))
  }

  @Test
  func testVerifyGmailPushWatchSendsHistoryProofWithoutProviderTokens() async throws {
    let fixtureEnvelope =
      #"{"status":"success","value":{"routeId":"route-001","verified":true}}"#.data(
        using: .utf8
      )!
    let client = ConvexClient(
      convexURL: URL(string: "https://example.convex.cloud")!,
      session: ConvexClientTesting.makeSession { request in
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/action")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer apple-token")
        let requestJSON = try requireValue(
          JSONSerialization.jsonObject(with: Self.requestBody(from: request)) as? [String: Any])
        #expect(requestJSON["path"] as? String == "pushRelay:verifyGmailWatch")
        let args = try requireValue(requestJSON["args"] as? [String: Any])
        #expect(args["gmailIdentityToken"] as? String == "gmail-identity-token")
        #expect(args["historyId"] as? String == "history-123")
        #expect(args["opaqueConnectionId"] as? String == "opaque-connection-001")
        #expect(args["trustedDeviceId"] as? String == "trustedDeviceFixtureId")
        #expect(args["accessToken"] == nil)
        #expect(args["refreshToken"] == nil)
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

    #expect(response.verified)
    #expect(response.routeId == "route-001")
  }

  private static func requestBody(from request: URLRequest) throws -> Data {
    if let body = request.httpBody {
      return body
    }

    let stream = try requireValue(request.httpBodyStream)
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

@Suite(.serialized)
final class ConvexClientProductSyncTests {
  @Test
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
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/mutation")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer apple-token")
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

    #expect(
      response == ProductSyncMaterialInitializedResponse(productSyncMaterialInitialized: true))
  }

  @Test
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
        #expect(request.url?.host() == "example.convex.site")
        #expect(request.url?.path == "/product-sync/recovery-material")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-apple-token")
        let requestJSON = try requireValue(
          JSONSerialization.jsonObject(with: Self.requestBody(from: request))
            as? [String: Any])
        #expect(requestJSON["payloadIdentifier"] == nil)
        #expect(requestJSON["trustedDeviceId"] as? String == "trustedDeviceFixtureId")
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

    #expect(response.payloadIdentifier == "product-account-recovery-v1")
  }

  @Test
  func testCustomConvexURLDerivesMatchingSiteURL() async {
    let client = ConvexClient(
      convexURL: URL(string: "https://custom.convex.cloud")!,
      session: ConvexClientTesting.makeSession { request in
        #expect(request.url?.host() == "custom.convex.site")
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
      Issue.record("Expected HTTP action error")
    } catch let error as ConvexClientError {
      #expect(error == .httpActionError(statusCode: 401, message: "Recent authentication required"))
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
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
      Issue.record("Expected trusted-device revocation")
    } catch let error as ConvexClientError {
      #expect(
        error
          == .convexApplicationFailure(
            status: "error",
            code: "TRUSTED_DEVICE_REVOKED",
            message: nil
          ))
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
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
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/query")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer apple-token")
        let requestBody = try Self.requestBody(from: request)
        let requestJSON = try requireValue(
          JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        let args = try requireValue(requestJSON["args"] as? [String: Any])
        #expect(args["trustedDeviceId"] as? String == "trusted-device-001")
        #expect(args["payloadIdentifierPrefix"] as? String == "message-category-learning-signal:")
        let paginationOpts = try requireValue(args["paginationOpts"] as? [String: Any])
        #expect(paginationOpts["numItems"] as? Int == 100)
        if requestCount == 1 {
          #expect(paginationOpts["cursor"] is NSNull)
        } else {
          #expect(paginationOpts["cursor"] as? String == "next-page")
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

    #expect(response.map(\.payloadIdentifier) == ["payload-001", "payload-002"])
    #expect(requestCount == 2)
  }

  @Test
  func testListEncryptedProductSyncPayloadPageMapsCursorAndLimit() async throws {
    let fixtureEnvelope = """
      {
        "status": "success",
        "value": {
          "continueCursor": "next-page",
          "isDone": false,
          "page": []
        }
      }
      """.data(using: .utf8)!
    let client = ConvexClient(
      convexURL: URL(string: "https://example.convex.cloud")!,
      session: ConvexClientTesting.makeSession { request in
        let requestJSON = try requireValue(
          JSONSerialization.jsonObject(with: Self.requestBody(from: request))
            as? [String: Any])
        #expect(
          requestJSON["path"] as? String == "productSync:listEncryptedPayloadsForTrustedDevice")
        let args = try requireValue(requestJSON["args"] as? [String: Any])
        let paginationOpts = try requireValue(args["paginationOpts"] as? [String: Any])
        #expect(paginationOpts["cursor"] as? String == "current-page")
        #expect(paginationOpts["numItems"] as? Int == 25)
        #expect(args["payloadIdentifierPrefix"] as? String == "record:")
        #expect(args["trustedDeviceId"] as? String == "trusted-device-001")
        return (convexClientTestResponse(for: request), fixtureEnvelope)
      }
    )

    let page = try await client.listEncryptedProductSyncPayloadPage(
      identityToken: "apple-token",
      payloadIdentifierPrefix: "record:",
      trustedDeviceId: "trusted-device-001",
      cursor: "current-page",
      limit: 25
    )

    #expect(page.continueCursor == "next-page")
    #expect(!(page.isDone))
  }

  @Test
  func testConditionalProductSyncWriteMapsExpectedRevision() async throws {
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
          "payloadIdentifier": "record:one",
          "updatedAt": 43
        }
      }
      """.data(using: .utf8)!
    let encryptedPayload = ProductSyncEncryptedPayload(
      algorithm: "AES-GCM-256",
      ciphertextBase64: "Y2lwaGVydGV4dA",
      keyVersion: 1,
      nonceBase64: "bm9uY2U",
      schemaVersion: 1,
      tagBase64: "dGFn"
    )
    let client = ConvexClient(
      convexURL: URL(string: "https://example.convex.cloud")!,
      session: ConvexClientTesting.makeSession { request in
        let requestJSON = try requireValue(
          JSONSerialization.jsonObject(with: Self.requestBody(from: request))
            as? [String: Any])
        #expect(requestJSON["path"] as? String == "productSync:putEncryptedPayloadIfUnchanged")
        let args = try requireValue(requestJSON["args"] as? [String: Any])
        #expect(args["expectedUpdatedAt"] as? Int == 42)
        #expect(args["payloadIdentifier"] as? String == "record:one")
        #expect(args["trustedDeviceId"] as? String == "trusted-device-001")
        let serializedPayload = try requireValue(args["encryptedPayload"] as? [String: Any])
        #expect(serializedPayload["algorithm"] as? String == encryptedPayload.algorithm)
        #expect(
          serializedPayload["ciphertextBase64"] as? String == encryptedPayload.ciphertextBase64)
        #expect(serializedPayload["keyVersion"] as? Int == encryptedPayload.keyVersion)
        #expect(serializedPayload["nonceBase64"] as? String == encryptedPayload.nonceBase64)
        #expect(serializedPayload["schemaVersion"] as? Int == encryptedPayload.schemaVersion)
        #expect(serializedPayload["tagBase64"] as? String == encryptedPayload.tagBase64)
        return (convexClientTestResponse(for: request), fixtureEnvelope)
      }
    )

    let written = try await client.putEncryptedProductSyncPayloadIfUnchanged(
      identityToken: "apple-token",
      payloadIdentifier: "record:one",
      encryptedPayload: encryptedPayload,
      trustedDeviceId: "trusted-device-001",
      expectedUpdatedAt: 42
    )

    #expect(written.payloadIdentifier == "record:one")
    #expect(written.updatedAt == 43)
  }

  @Test
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
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/query")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer apple-token")
        let requestBody = try Self.requestBody(from: request)
        let requestJSON = try requireValue(
          JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        let args = try requireValue(requestJSON["args"] as? [String: Any])
        #expect(args["trustedDeviceId"] as? String == "trusted-device-001")
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

    #expect(response?.payloadIdentifier == "custom-category-primary")
  }

  @Test
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
        let requestJSON = try requireValue(
          JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        #expect(
          requestJSON["path"] as? String == "productSync:getEncryptedPayloadsForTrustedDevice")
        let args = try requireValue(requestJSON["args"] as? [String: Any])
        #expect(args["payloadIdentifiers"] as? [String] == ["payload-001"])
        #expect(args["trustedDeviceId"] as? String == "trusted-device-001")
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

    #expect(response.isEmpty)
  }

  @Test
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

    #expect(response == nil)
  }

  @Test
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
      Issue.record("Expected Convex error envelope")
    } catch let error as ConvexClientError {
      #expect(error == .convexFailure(status: "error", message: "Authentication required"))
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
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
      Issue.record("Expected Convex application error envelope")
    } catch let error as ConvexClientError {
      #expect(
        error
          == .convexApplicationFailure(
            status: "error",
            code: "TRUSTED_DEVICE_REVOKED",
            message: "Server Error"
          ))
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
  func testProductAccountServiceTranslatesRevocationWhileMarkingSyncInitialized() async {
    let service = ConvexProductAccountService(client: revokedDeviceClient())

    do {
      _ = try await service.markProductSyncMaterialInitialized(
        identityToken: "apple-token",
        trustedDeviceId: "trusted-device-001"
      )
      Issue.record("Expected trusted-device revocation")
    } catch let error as ProductAccountServiceError {
      #expect(error == .trustedDeviceRevoked)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
  func testProductAccountServiceTranslatesRevocationWhileLoadingRecoveryMaterial() async {
    let service = ConvexProductAccountService(client: revokedDeviceClient())

    do {
      _ = try await service.productSyncRecoveryMaterial(
        identityToken: "apple-token",
        trustedDeviceId: "trusted-device-001"
      )
      Issue.record("Expected trusted-device revocation")
    } catch let error as ProductAccountServiceError {
      #expect(error == .trustedDeviceRevoked)
    } catch {
      Issue.record("Unexpected error: \(error)")
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

  @Test
  func testConvexApplicationErrorEnvelopeFallsBackForEmptyMessage() {
    let error = ConvexClientError.convexApplicationFailure(
      status: "error",
      code: "PRODUCT_ACCOUNT_DELETED",
      message: ""
    )

    #expect(error.localizedDescription == "The backend rejected the request.")
  }

  @Test
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

    #expect(!(response.deleted))
    #expect(requestCount == 1)
  }

  @Test
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

    #expect(response.deleted)
  }

  @Test
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
      Issue.record("Expected deleted Product Account error")
    } catch {
      #expect(error as? ProductAccountServiceError == .productAccountDeleted)
    }
  }

  private static func requestBody(from request: URLRequest) throws -> Data {
    if let body = request.httpBody {
      return body
    }

    let stream = try requireValue(request.httpBodyStream)
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
