import Foundation

// swiftlint:disable file_length

enum ConvexClientError: LocalizedError, Equatable {
  case missingConvexURL
  case httpError(statusCode: Int)
  case convexFailure(status: String, message: String?)
  case decodeError

  var errorDescription: String? {
    switch self {
    case .missingConvexURL:
      return
        "Set CONVEX_URL in the scheme environment, apps/unwired-mail/.env.local, or local Xcode configuration."
    case .httpError(let statusCode):
      return "The backend returned HTTP status \(statusCode)."
    case .convexFailure(let status, let message):
      if let message, !message.isEmpty {
        return message
      }
      return "The backend returned status '\(status)'."
    case .decodeError:
      return "The backend returned an unexpected response."
    }
  }
}

// swiftlint:disable:next type_body_length
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

  func markProductSyncMaterialInitialized(
    identityToken: String,
    trustedDeviceId: String
  ) async throws -> ProductSyncMaterialInitializedResponse {
    try await performMutation(
      path: "productAccount:markProductSyncMaterialInitialized",
      args: MarkProductSyncMaterialInitializedArgs(
        trustedDeviceId: trustedDeviceId
      ),
      identityToken: identityToken
    )
  }

  func registerGmailConnection(
    gmailIdentityToken: String,
    identityToken: String,
    opaqueConnectionId: String,
    trustedDeviceId: String
  ) async throws -> GmailOperationalConnectionStatus {
    try await performAction(
      path: "pushRelay:registerGmailConnection",
      args: RegisterGmailConnectionArgs(
        gmailIdentityToken: gmailIdentityToken,
        opaqueConnectionId: opaqueConnectionId,
        trustedDeviceId: trustedDeviceId
      ),
      identityToken: identityToken
    )
  }

  func removeGmailConnection(
    identityToken: String,
    opaqueConnectionId: String,
    trustedDeviceId: String
  ) async throws -> Bool {
    let response: RemoveGmailProviderConnectionResponse = try await performMutation(
      path: "pushRelay:removeGmailConnection",
      args: RemoveGmailProviderConnectionArgs(
        opaqueConnectionId: opaqueConnectionId,
        trustedDeviceId: trustedDeviceId
      ),
      identityToken: identityToken
    )
    return response.hasRemainingGmailConnections
  }

  func shouldStopGmailPushWatch(
    identityToken: String,
    opaqueConnectionId: String,
    trustedDeviceId: String
  ) async throws -> Bool {
    try await performQuery(
      path: "pushRelay:shouldStopGmailWatch",
      args: ShouldStopGmailPushWatchArgs(
        opaqueConnectionId: opaqueConnectionId,
        trustedDeviceId: trustedDeviceId
      ),
      identityToken: identityToken
    )
  }

  func registerDevicePush(
    apnsEnvironment: String,
    apnsToken: String,
    identityToken: String,
    trustedDeviceId: String
  ) async throws -> DevicePushRegistrationResponse {
    try await performMutation(
      path: "pushRelay:registerDevice",
      args: RegisterDevicePushArgs(
        apnsEnvironment: apnsEnvironment,
        apnsToken: apnsToken,
        trustedDeviceId: trustedDeviceId
      ),
      identityToken: identityToken
    )
  }

  func unregisterDevicePush(
    identityToken: String,
    trustedDeviceId: String
  ) async throws -> DevicePushRegistrationResponse {
    try await performMutation(
      path: "pushRelay:unregisterDevice",
      args: UnregisterDevicePushArgs(trustedDeviceId: trustedDeviceId),
      identityToken: identityToken
    )
  }

  func verifyGmailPushWatch(
    gmailIdentityToken: String,
    historyId: String,
    identityToken: String,
    opaqueConnectionId: String,
    trustedDeviceId: String
  ) async throws -> GmailPushVerificationResponse {
    try await performAction(
      path: "pushRelay:verifyGmailWatch",
      args: VerifyGmailPushWatchArgs(
        gmailIdentityToken: gmailIdentityToken,
        historyId: historyId,
        opaqueConnectionId: opaqueConnectionId,
        trustedDeviceId: trustedDeviceId
      ),
      identityToken: identityToken
    )
  }

  func prepareMicrosoftGraphPushRoute(
    clientStateDigest: String,
    identityToken: String,
    opaqueConnectionId: String,
    trustedDeviceId: String
  ) async throws -> MicrosoftGraphPushRouteResponse {
    try await performMutation(
      path: "pushRelay:prepareMicrosoftGraphRoute",
      args: PrepareMicrosoftGraphPushRouteArgs(
        clientStateDigest: clientStateDigest,
        opaqueConnectionId: opaqueConnectionId,
        trustedDeviceId: trustedDeviceId
      ),
      identityToken: identityToken
    )
  }

  func confirmMicrosoftGraphPushRoute(
    confirmation: MicrosoftGraphPushRouteConfirmation,
    identityToken: String,
    trustedDeviceId: String
  ) async throws -> MicrosoftGraphPushRouteResponse {
    try await performMutation(
      path: "pushRelay:confirmMicrosoftGraphRoute",
      args: ConfirmMicrosoftGraphPushRouteArgs(
        clientStateDigest: confirmation.clientStateDigest,
        expiresAt: confirmation.expiresAt,
        routeId: confirmation.routeId,
        subscriptionId: confirmation.subscriptionId,
        trustedDeviceId: trustedDeviceId
      ),
      identityToken: identityToken
    )
  }

  func rollbackMicrosoftGraphPushRoute(
    clientStateDigest: String,
    identityToken: String,
    routeId: String,
    trustedDeviceId: String
  ) async throws -> Bool {
    let response: RollbackMicrosoftGraphPushRouteResponse = try await performMutation(
      path: "pushRelay:rollbackMicrosoftGraphRoute",
      args: RollbackMicrosoftGraphPushRouteArgs(
        clientStateDigest: clientStateDigest,
        routeId: routeId,
        trustedDeviceId: trustedDeviceId
      ),
      identityToken: identityToken
    )
    return response.rolledBack
  }

  func removeMicrosoftGraphPushRoute(
    identityToken: String,
    opaqueConnectionId: String,
    trustedDeviceId: String
  ) async throws -> Bool {
    let response: RemoveMicrosoftGraphPushRouteResponse = try await performMutation(
      path: "pushRelay:removeMicrosoftGraphRoute",
      args: RemoveMicrosoftGraphPushRouteArgs(
        opaqueConnectionId: opaqueConnectionId,
        trustedDeviceId: trustedDeviceId
      ),
      identityToken: identityToken
    )
    return response.removed
  }

  func putEncryptedProductSyncPayload(
    identityToken: String,
    payloadIdentifier: String,
    encryptedPayload: ProductSyncEncryptedPayload,
    trustedDeviceId: String
  ) async throws -> EncryptedProductSyncPayload {
    try await performMutation(
      path: "productSync:putEncryptedPayload",
      args: PutEncryptedProductSyncPayloadArgs(
        encryptedPayload: encryptedPayload,
        payloadIdentifier: payloadIdentifier,
        trustedDeviceId: trustedDeviceId
      ),
      identityToken: identityToken
    )
  }

  func putEncryptedProductSyncPayloadIfAbsent(
    identityToken: String,
    payloadIdentifier: String,
    encryptedPayload: ProductSyncEncryptedPayload,
    trustedDeviceId: String
  ) async throws -> EncryptedProductSyncPayload {
    try await performMutation(
      path: "productSync:putEncryptedPayloadIfAbsent",
      args: PutEncryptedProductSyncPayloadArgs(
        encryptedPayload: encryptedPayload,
        payloadIdentifier: payloadIdentifier,
        trustedDeviceId: trustedDeviceId
      ),
      identityToken: identityToken
    )
  }

  func putEncryptedProductSyncPayloadIfUnchanged(
    identityToken: String,
    payloadIdentifier: String,
    encryptedPayload: ProductSyncEncryptedPayload,
    trustedDeviceId: String,
    expectedUpdatedAt: Int64?
  ) async throws -> EncryptedProductSyncPayload {
    try await performMutation(
      path: "productSync:putEncryptedPayloadIfUnchanged",
      args: PutEncryptedPayloadIfUnchangedArgs(
        encryptedPayload: encryptedPayload,
        expectedUpdatedAt: expectedUpdatedAt,
        payloadIdentifier: payloadIdentifier,
        trustedDeviceId: trustedDeviceId
      ),
      identityToken: identityToken
    )
  }

  func getEncryptedProductSyncPayload(
    identityToken: String,
    payloadIdentifier: String
  ) async throws -> EncryptedProductSyncPayload? {
    try await performNullableQuery(
      path: "productSync:getEncryptedPayload",
      args: GetEncryptedProductSyncPayloadArgs(payloadIdentifier: payloadIdentifier),
      identityToken: identityToken
    )
  }

  func getEncryptedProductSyncPayloads(
    identityToken: String,
    payloadIdentifiers: [String]
  ) async throws -> [EncryptedProductSyncPayload] {
    try await performQuery(
      path: "productSync:getEncryptedPayloads",
      args: GetEncryptedProductSyncPayloadsArgs(payloadIdentifiers: payloadIdentifiers),
      identityToken: identityToken
    )
  }

  func listEncryptedProductSyncPayloads(
    identityToken: String,
    payloadIdentifierPrefix: String? = nil
  ) async throws -> [EncryptedProductSyncPayload] {
    var allPayloads: [EncryptedProductSyncPayload] = []
    var cursor: String?
    var isDone = false

    while !isDone {
      let response: EncryptedProductSyncPayloadPage = try await performQuery(
        path: "productSync:listEncryptedPayloads",
        args: ListEncryptedProductSyncPayloadsArgs(
          paginationOpts: ConvexPaginationOptions(
            cursor: cursor,
            numItems: 100
          ),
          payloadIdentifierPrefix: payloadIdentifierPrefix
        ),
        identityToken: identityToken
      )

      allPayloads.append(contentsOf: response.page)
      cursor = response.continueCursor
      isDone = response.isDone
    }

    return allPayloads
  }

  private func performAction<Response: Decodable>(
    path: String,
    args: some Encodable = EmptyConvexArgs(),
    identityToken: String? = nil
  ) async throws -> Response {
    try await performRequest(
      endpoint: "api/action",
      path: path,
      args: args,
      identityToken: identityToken
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

  private func performQuery<Response: Decodable>(
    path: String,
    args: some Encodable = EmptyConvexArgs(),
    identityToken: String
  ) async throws -> Response {
    try await performRequest(
      endpoint: "api/query",
      path: path,
      args: args,
      identityToken: identityToken
    )
  }

  private func performNullableQuery<Response: Decodable>(
    path: String,
    args: some Encodable = EmptyConvexArgs(),
    identityToken: String
  ) async throws -> Response? {
    try await performNullableRequest(
      endpoint: "api/query",
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
      throw ConvexClientError.convexFailure(
        status: functionResponse.status,
        message: functionResponse.errorMessage
      )
    }

    guard let value = functionResponse.value else {
      throw ConvexClientError.decodeError
    }

    return value
  }

  private func performNullableRequest<Response: Decodable>(
    endpoint: String,
    path: String,
    args: some Encodable,
    identityToken: String?
  ) async throws -> Response? {
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
      throw ConvexClientError.convexFailure(
        status: functionResponse.status,
        message: functionResponse.errorMessage
      )
    }

    return functionResponse.value
  }
}

private struct EmptyConvexArgs: Encodable {}

private struct ConnectProductAccountArgs: Encodable {
  let deviceIdentifier: String
  let platform: String
}

private struct RegisterGmailConnectionArgs: Encodable {
  let gmailIdentityToken: String
  let opaqueConnectionId: String
  let trustedDeviceId: String
}

private struct RegisterDevicePushArgs: Encodable {
  let apnsEnvironment: String
  let apnsToken: String
  let trustedDeviceId: String
}

private struct ShouldStopGmailPushWatchArgs: Encodable {
  let opaqueConnectionId: String
  let trustedDeviceId: String
}

private struct RemoveGmailProviderConnectionArgs: Encodable {
  let opaqueConnectionId: String
  let trustedDeviceId: String
}

private struct RemoveGmailProviderConnectionResponse: Decodable {
  let hasRemainingGmailConnections: Bool
  let removed: Bool
}

private struct UnregisterDevicePushArgs: Encodable {
  let trustedDeviceId: String
}

private struct VerifyGmailPushWatchArgs: Encodable {
  let gmailIdentityToken: String
  let historyId: String
  let opaqueConnectionId: String
  let trustedDeviceId: String
}

private struct PrepareMicrosoftGraphPushRouteArgs: Encodable {
  let clientStateDigest: String
  let opaqueConnectionId: String
  let trustedDeviceId: String
}

private struct ConfirmMicrosoftGraphPushRouteArgs: Encodable {
  let clientStateDigest: String?
  let expiresAt: Int64
  let routeId: String
  let subscriptionId: String
  let trustedDeviceId: String
}

private struct RollbackMicrosoftGraphPushRouteArgs: Encodable {
  let clientStateDigest: String
  let routeId: String
  let trustedDeviceId: String
}

private struct RollbackMicrosoftGraphPushRouteResponse: Decodable {
  let rolledBack: Bool
}

private struct RemoveMicrosoftGraphPushRouteArgs: Encodable {
  let opaqueConnectionId: String
  let trustedDeviceId: String
}

private struct RemoveMicrosoftGraphPushRouteResponse: Decodable {
  let removed: Bool
}

private struct PutEncryptedProductSyncPayloadArgs: Encodable {
  let encryptedPayload: ProductSyncEncryptedPayload
  let payloadIdentifier: String
  let trustedDeviceId: String
}

private struct PutEncryptedPayloadIfUnchangedArgs: Encodable {
  let encryptedPayload: ProductSyncEncryptedPayload
  let expectedUpdatedAt: Int64?
  let payloadIdentifier: String
  let trustedDeviceId: String
}

private struct GetEncryptedProductSyncPayloadArgs: Encodable {
  let payloadIdentifier: String
}

private struct GetEncryptedProductSyncPayloadsArgs: Encodable {
  let payloadIdentifiers: [String]
}

private struct MarkProductSyncMaterialInitializedArgs: Encodable {
  let trustedDeviceId: String
}

private struct ListEncryptedProductSyncPayloadsArgs: Encodable {
  let paginationOpts: ConvexPaginationOptions
  let payloadIdentifierPrefix: String?
}

private struct ConvexPaginationOptions: Encodable {
  let cursor: String?
  let numItems: Int

  enum CodingKeys: CodingKey {
    case cursor
    case numItems
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(cursor, forKey: .cursor)
    try container.encode(numItems, forKey: .numItems)
  }
}

private struct ConvexFunctionRequest: Encodable {
  let path: String
  let args: AnyEncodable
  let format: String
}

private struct ConvexFunctionEnvelope<Value: Decodable>: Decodable {
  let status: String
  let value: Value?
  let errorMessage: String?
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

#if DEBUG || TESTING
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

    override static func canInit(with request: URLRequest) -> Bool {
      true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
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
