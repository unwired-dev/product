import Foundation

// swiftlint:disable file_length

enum ConvexClientError: LocalizedError, Equatable {
  case missingConvexURL
  case insecureConvexURL
  case httpError(statusCode: Int)
  case convexApplicationFailure(status: String, code: String, message: String?)
  case httpActionError(statusCode: Int, message: String?)
  case convexFailure(status: String, message: String?)
  case decodeError

  var errorDescription: String? {
    switch self {
    case .missingConvexURL:
      return
        "Set CONVEX_URL in the scheme environment, apps/unwired-mail/.env.local, or local Xcode configuration."
    case .insecureConvexURL:
      return "Authenticated backend requests require an HTTPS Convex URL."
    case .httpError(let statusCode):
      return "The backend returned HTTP status \(statusCode)."
    case .convexApplicationFailure(_, _, let message):
      if let message, !message.isEmpty {
        return message
      }
      return "The backend rejected the request."
    case .httpActionError(let statusCode, let message):
      if let message, !message.isEmpty {
        return message
      }
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
  private let convexSiteURL: URL?
  private let convexURL: URL?
  private let scheduledDeliveryAuthorizationStore: ScheduledDeliveryAuthorizationPersisting
  private let session: URLSession
  private let trustedDeviceCredentialStore: TrustedDeviceCredentialPersisting

  convenience init(
    convexURL: URL? = BackendEnvironment.convexURL,
    session: URLSession = .shared,
    scheduledDeliveryAuthorizationStore: ScheduledDeliveryAuthorizationPersisting? = nil,
    trustedDeviceCredentialStore: TrustedDeviceCredentialPersisting? = nil
  ) {
    let convexSiteURL =
      convexURL == BackendEnvironment.convexURL
      ? BackendEnvironment.convexSiteURL
      : BackendEnvironment.resolveConvexSiteURL(explicitValue: nil, convexURL: convexURL)
    self.init(
      convexURL: convexURL,
      convexSiteURL: convexSiteURL,
      session: session,
      scheduledDeliveryAuthorizationStore: scheduledDeliveryAuthorizationStore,
      trustedDeviceCredentialStore: trustedDeviceCredentialStore
    )
  }

  init(
    convexURL: URL?,
    convexSiteURL: URL?,
    session: URLSession = .shared,
    scheduledDeliveryAuthorizationStore: ScheduledDeliveryAuthorizationPersisting? = nil,
    trustedDeviceCredentialStore: TrustedDeviceCredentialPersisting? = nil
  ) {
    self.convexURL = convexURL
    self.convexSiteURL = convexSiteURL
    self.scheduledDeliveryAuthorizationStore =
      scheduledDeliveryAuthorizationStore ?? KeychainScheduledDeliveryAuthStore()
    self.session = session
    self.trustedDeviceCredentialStore =
      trustedDeviceCredentialStore ?? KeychainTrustedDeviceCredentialStore()
  }

  private func trustedDeviceCredential(_ trustedDeviceId: String) throws -> String? {
    try trustedDeviceCredentialStore.load(trustedDeviceId: trustedDeviceId)
  }

  private func scheduledDeliveryAuthorization(
    _ trustedDeviceId: String
  ) throws -> ScheduledDeliveryAuthorization {
    guard
      let authorization = try scheduledDeliveryAuthorizationStore.load(
        trustedDeviceId: trustedDeviceId
      )
    else { throw ScheduledDeliveryAuthorizationError.missing }
    return authorization
  }

  func health() async throws -> HealthResponse {
    try await performAction(path: "health:health")
  }

  func connectProductAccount(
    identityToken: String,
    deviceIdentifier: String,
    deviceName: String,
    platform: String,
    trustedDeviceCredential: String? = nil
  ) async throws -> ProductAccountConnectResponse {
    try await performMutation(
      path: "productAccount:connect",
      args: ConnectProductAccountArgs(
        deviceIdentifier: deviceIdentifier,
        deviceName: deviceName,
        platform: platform,
        supportsDeviceCredentials: true,
        trustedDeviceCredential: trustedDeviceCredential
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
        trustedDeviceCredential: try trustedDeviceCredential(trustedDeviceId),
        trustedDeviceId: trustedDeviceId
      ),
      identityToken: identityToken
    )
  }

  func listTrustedDevices(
    identityToken: String,
    trustedDeviceId: String
  ) async throws -> [TrustedDeviceSummary] {
    try await performQuery(
      path: "productAccount:listTrustedDevices",
      args: ListTrustedDevicesArgs(
        trustedDeviceCredential: try trustedDeviceCredential(trustedDeviceId),
        trustedDeviceId: trustedDeviceId
      ),
      identityToken: identityToken
    )
  }

  func renameTrustedDevice(
    displayName: String,
    identityToken: String,
    trustedDeviceId: String,
    trustedDeviceToRenameId: String
  ) async throws -> TrustedDeviceSummary {
    try await performMutation(
      path: "productAccount:renameTrustedDevice",
      args: RenameTrustedDeviceArgs(
        displayName: displayName,
        trustedDeviceCredential: try trustedDeviceCredential(trustedDeviceId),
        trustedDeviceId: trustedDeviceId,
        trustedDeviceToRenameId: trustedDeviceToRenameId
      ),
      identityToken: identityToken
    )
  }

  func unregisterTrustedDevice(
    deviceIdentifier: String,
    identityToken: String,
    trustedDeviceId: String
  ) async throws -> TrustedDeviceUnregistrationResponse {
    try await performMutation(
      path: "productAccount:unregisterTrustedDevice",
      args: UnregisterTrustedDeviceArgs(
        deviceIdentifier: deviceIdentifier,
        trustedDeviceCredential: try trustedDeviceCredential(trustedDeviceId),
        trustedDeviceId: trustedDeviceId
      ),
      identityToken: identityToken
    )
  }

  // swiftlint:disable:next function_parameter_count
  func revokeTrustedDevice(
    encryptedTransition: ProductSyncEncryptedPayload,
    expectedRecoveryUpdatedAt: Int64,
    identityToken: String,
    recoveryWrappedAccountKey: ProductSyncEncryptedPayload,
    trustedDeviceId: String,
    trustedDeviceToRevokeId: String
  ) async throws -> ProductSyncKeyRotationResponse {
    try await performMutation(
      path: "productAccount:revokeTrustedDevice",
      args: RevokeTrustedDeviceArgs(
        encryptedTransition: encryptedTransition,
        expectedRecoveryUpdatedAt: expectedRecoveryUpdatedAt,
        recoveryWrappedAccountKey: recoveryWrappedAccountKey,
        trustedDeviceCredential: try trustedDeviceCredential(trustedDeviceId),
        trustedDeviceId: trustedDeviceId,
        trustedDeviceToRevokeId: trustedDeviceToRevokeId
      ),
      identityToken: identityToken
    )
  }

  func productSyncKeyRotation(
    identityToken: String,
    trustedDeviceId: String
  ) async throws -> ProductSyncKeyRotationStatus? {
    try await performNullableQuery(
      path: "productAccount:getProductSyncKeyRotation",
      args: ProductSyncKeyRotationArgs(
        trustedDeviceCredential: try trustedDeviceCredential(trustedDeviceId),
        trustedDeviceId: trustedDeviceId
      ),
      identityToken: identityToken
    )
  }

  func acknowledgeProductSyncKeyRotation(
    identityToken: String,
    keyEpoch: Int,
    trustedDeviceId: String
  ) async throws -> ProductSyncKeyRotationResponse {
    try await performMutation(
      path: "productAccount:acknowledgeProductSyncKeyRotation",
      args: AcknowledgeProductSyncKeyRotationArgs(
        keyEpoch: keyEpoch,
        trustedDeviceCredential: try trustedDeviceCredential(trustedDeviceId),
        trustedDeviceId: trustedDeviceId
      ),
      identityToken: identityToken
    )
  }

  func deleteProductAccount(
    authorizationCode: String,
    identityToken: String,
    trustedDeviceId: String
  ) async throws -> ProductAccountDeletionResponse {
    try await performAction(
      path: "productAccountDeletion:deleteProductAccount",
      args: DeleteProductAccountArgs(
        authorizationCode: authorizationCode,
        trustedDeviceCredential: try trustedDeviceCredential(trustedDeviceId),
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
        trustedDeviceCredential: try trustedDeviceCredential(trustedDeviceId),
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
        trustedDeviceCredential: try trustedDeviceCredential(trustedDeviceId),
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
        trustedDeviceCredential: try trustedDeviceCredential(trustedDeviceId),
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
        trustedDeviceCredential: try trustedDeviceCredential(trustedDeviceId),
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
      args: UnregisterDevicePushArgs(
        trustedDeviceCredential: try trustedDeviceCredential(trustedDeviceId),
        trustedDeviceId: trustedDeviceId
      ),
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
        trustedDeviceCredential: try trustedDeviceCredential(trustedDeviceId),
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
        trustedDeviceCredential: try trustedDeviceCredential(trustedDeviceId),
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
        trustedDeviceCredential: try trustedDeviceCredential(trustedDeviceId),
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
        trustedDeviceCredential: try trustedDeviceCredential(trustedDeviceId),
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
        trustedDeviceCredential: try trustedDeviceCredential(trustedDeviceId),
        trustedDeviceId: trustedDeviceId
      ),
      identityToken: identityToken
    )
    return response.removed
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
        trustedDeviceCredential: try trustedDeviceCredential(trustedDeviceId),
        trustedDeviceId: trustedDeviceId
      ),
      identityToken: identityToken
    )
  }

  func putEncryptedProductSyncPayloadsAtomically(
    identityToken: String,
    writes: [ProductSyncAtomicWrite],
    deletes: [ProductSyncAtomicDelete],
    checks: [ProductSyncAtomicCheck],
    trustedDeviceId: String
  ) async throws -> ProductSyncAtomicWriteResult {
    let response: PutEncryptedPayloadsAtomicallyResponse = try await performMutation(
      path: "productSync:putEncryptedPayloadsAtomically",
      args: PutEncryptedPayloadsAtomicallyArgs(
        checks: checks.map(AtomicPayloadRevisionArgs.init),
        deletes: deletes.map(AtomicPayloadRevisionArgs.init),
        trustedDeviceCredential: try trustedDeviceCredential(trustedDeviceId),
        trustedDeviceId: trustedDeviceId,
        writes: writes.map(AtomicPayloadWriteArgs.init)
      ),
      identityToken: identityToken
    )
    return ProductSyncAtomicWriteResult(
      committed: response.committed,
      payloads: response.payloads
    )
  }

  func replaceRecoveryMaterialIfUnchanged(
    identityToken: String,
    encryptedPayload: ProductSyncEncryptedPayload,
    trustedDeviceId: String,
    expectedUpdatedAt: Int64?
  ) async throws -> EncryptedProductSyncPayload {
    try await performHTTPAction(
      path: "product-sync/recovery-material",
      args: ReplaceRecoveryMaterialIfUnchangedArgs(
        encryptedPayload: encryptedPayload,
        expectedUpdatedAt: expectedUpdatedAt,
        trustedDeviceCredential: try trustedDeviceCredential(trustedDeviceId),
        trustedDeviceId: trustedDeviceId
      ),
      identityToken: identityToken
    )
  }

  func getEncryptedProductSyncPayload(
    identityToken: String,
    payloadIdentifier: String,
    trustedDeviceId: String
  ) async throws -> EncryptedProductSyncPayload? {
    try await performNullableQuery(
      path: "productSync:getEncryptedPayloadForTrustedDevice",
      args: GetEncryptedProductSyncPayloadArgs(
        payloadIdentifier: payloadIdentifier,
        trustedDeviceCredential: try trustedDeviceCredential(trustedDeviceId),
        trustedDeviceId: trustedDeviceId
      ),
      identityToken: identityToken
    )
  }

  func getEncryptedProductSyncPayloads(
    identityToken: String,
    payloadIdentifiers: [String],
    trustedDeviceId: String
  ) async throws -> [EncryptedProductSyncPayload] {
    try await performQuery(
      path: "productSync:getEncryptedPayloadsForTrustedDevice",
      args: GetEncryptedProductSyncPayloadsArgs(
        payloadIdentifiers: payloadIdentifiers,
        trustedDeviceCredential: try trustedDeviceCredential(trustedDeviceId),
        trustedDeviceId: trustedDeviceId
      ),
      identityToken: identityToken
    )
  }

  func listEncryptedProductSyncPayloads(
    identityToken: String,
    payloadIdentifierPrefix: String? = nil,
    trustedDeviceId: String
  ) async throws -> [EncryptedProductSyncPayload] {
    var allPayloads: [EncryptedProductSyncPayload] = []
    var cursor: String?
    var isDone = false

    while !isDone {
      let response = try await listEncryptedProductSyncPayloadPage(
        identityToken: identityToken,
        payloadIdentifierPrefix: payloadIdentifierPrefix,
        trustedDeviceId: trustedDeviceId,
        cursor: cursor,
        limit: 100
      )

      allPayloads.append(contentsOf: response.page)
      cursor = response.continueCursor
      isDone = response.isDone
    }

    return allPayloads
  }

  func listEncryptedProductSyncPayloadPage(
    identityToken: String,
    payloadIdentifierPrefix: String?,
    trustedDeviceId: String,
    cursor: String?,
    limit: Int
  ) async throws -> EncryptedProductSyncPayloadPage {
    try await performQuery(
      path: "productSync:listEncryptedPayloadsForTrustedDevice",
      args: ListEncryptedProductSyncPayloadsArgs(
        paginationOpts: ConvexPaginationOptions(cursor: cursor, numItems: limit),
        payloadIdentifierPrefix: payloadIdentifierPrefix,
        trustedDeviceCredential: try trustedDeviceCredential(trustedDeviceId),
        trustedDeviceId: trustedDeviceId
      ),
      identityToken: identityToken
    )
  }

  func admitScheduledSend(
    _ record: ScheduledSendRecord,
    payload: ScheduledSendPayloadAcknowledgement,
    session: ProductAccountSessionSnapshot
  ) async throws -> ScheduledSendOperationalAcknowledgement {
    try await performMutation(
      path: "scheduledSend:admit",
      args: AdmitScheduledSendArgs(
        deadlineAt: record.deadlineAtMilliseconds,
        dueAt: record.dueAtMilliseconds,
        encryptedPayloadIdentifier: payload.payloadIdentifier,
        encryptedPayloadUpdatedAt: payload.updatedAt,
        revision: record.revision,
        scheduleId: record.scheduleId.uuidString.lowercased(),
        trustedDeviceCredential: try trustedDeviceCredential(session.trustedDeviceId),
        trustedDeviceId: session.trustedDeviceId
      ),
      identityToken: session.identityToken
    )
  }

  func cancelScheduledSend(
    scheduleId: UUID,
    revision: Int,
    session: ProductAccountSessionSnapshot
  ) async throws -> Bool {
    try await cancelScheduledSend(
      scheduleId: scheduleId,
      revision: revision,
      editGeneration: nil,
      session: session
    )
  }

  func cancelScheduledSend(
    scheduleId: UUID,
    revision: Int,
    editGeneration: Int?,
    session: ProductAccountSessionSnapshot
  ) async throws -> Bool {
    try await performMutation(
      path: "scheduledSend:cancel",
      args: CancelScheduledSendArgs(
        editGeneration: editGeneration,
        revision: revision,
        scheduleId: scheduleId.uuidString.lowercased(),
        trustedDeviceCredential: try trustedDeviceCredential(session.trustedDeviceId),
        trustedDeviceId: session.trustedDeviceId
      ),
      identityToken: session.identityToken
    )
  }

  func scheduledSendStatus(
    scheduleId: UUID,
    session: ProductAccountSessionSnapshot
  ) async throws -> ScheduledSendOperationalStatus? {
    try await performNullableQuery(
      path: "scheduledSend:status",
      args: ScheduledSendStatusArgs(
        scheduleId: scheduleId.uuidString.lowercased(),
        trustedDeviceCredential: try trustedDeviceCredential(session.trustedDeviceId),
        trustedDeviceId: session.trustedDeviceId
      ),
      identityToken: session.identityToken
    )
  }

  func beginScheduledSendEdit(
    scheduleId: UUID,
    revision: Int,
    session: ProductAccountSessionSnapshot
  ) async throws -> ScheduledSendEditLeaseResult {
    let response: ScheduledSendEditLeaseWireResponse = try await performMutation(
      path: "scheduledSend:beginEdit",
      args: BeginScheduledSendEditArgs(
        revision: revision,
        scheduleId: scheduleId.uuidString.lowercased(),
        trustedDeviceCredential: try trustedDeviceCredential(session.trustedDeviceId),
        trustedDeviceId: session.trustedDeviceId
      ),
      identityToken: session.identityToken
    )
    return try response.result()
  }

  func releaseScheduledSendEdit(
    scheduleId: UUID,
    revision: Int,
    editGeneration: Int,
    session: ProductAccountSessionSnapshot
  ) async throws -> Bool {
    try await performMutation(
      path: "scheduledSend:releaseEdit",
      args: ReleaseScheduledSendEditArgs(
        editGeneration: editGeneration,
        revision: revision,
        scheduleId: scheduleId.uuidString.lowercased(),
        trustedDeviceCredential: try trustedDeviceCredential(session.trustedDeviceId),
        trustedDeviceId: session.trustedDeviceId
      ),
      identityToken: session.identityToken
    )
  }

  func rescheduleScheduledSend(
    _ record: ScheduledSendRecord,
    payload: ScheduledSendPayloadAcknowledgement,
    expectedRevision: Int,
    editGeneration: Int,
    session: ProductAccountSessionSnapshot
  ) async throws -> ScheduledSendOperationalAcknowledgement {
    try await replaceScheduledSend(
      path: "scheduledSend:reschedule",
      record: record,
      payload: payload,
      expectedRevision: expectedRevision,
      editGeneration: editGeneration,
      session: session
    )
  }

  func sendScheduledSendNow(
    _ record: ScheduledSendRecord,
    payload: ScheduledSendPayloadAcknowledgement,
    expectedRevision: Int,
    editGeneration: Int,
    session: ProductAccountSessionSnapshot
  ) async throws -> ScheduledSendOperationalAcknowledgement {
    try await replaceScheduledSend(
      path: "scheduledSend:sendNow",
      record: record,
      payload: payload,
      expectedRevision: expectedRevision,
      editGeneration: editGeneration,
      requestedAt: Int64(Date.now.timeIntervalSince1970 * 1_000),
      session: session
    )
  }

  // swiftlint:disable:next function_parameter_count
  private func replaceScheduledSend(
    path: String,
    record: ScheduledSendRecord,
    payload: ScheduledSendPayloadAcknowledgement,
    expectedRevision: Int,
    editGeneration: Int,
    requestedAt: Int64? = nil,
    session: ProductAccountSessionSnapshot
  ) async throws -> ScheduledSendOperationalAcknowledgement {
    try await performMutation(
      path: path,
      args: ReplaceScheduledSendArgs(
        deadlineAt: record.deadlineAtMilliseconds,
        dueAt: record.dueAtMilliseconds,
        editGeneration: editGeneration,
        encryptedPayloadIdentifier: payload.payloadIdentifier,
        encryptedPayloadUpdatedAt: payload.updatedAt,
        expectedRevision: expectedRevision,
        requestedAt: requestedAt,
        revision: record.revision,
        scheduleId: record.scheduleId.uuidString.lowercased(),
        trustedDeviceCredential: try trustedDeviceCredential(session.trustedDeviceId),
        trustedDeviceId: session.trustedDeviceId
      ),
      identityToken: session.identityToken
    )
  }

  func registerScheduledDeliveryCapability(
    session: ProductAccountSessionSnapshot
  ) async throws -> ScheduledDeliveryAuthorization {
    let currentAuthorization = try scheduledDeliveryAuthorizationStore.load(
      trustedDeviceId: session.trustedDeviceId
    )
    let authorization: ScheduledDeliveryAuthorization = try await performMutation(
      path: "scheduledSend:registerDeliveryCapability",
      args: RegisterScheduledDeliveryCapabilityArgs(
        capabilityVersion: 1,
        scheduledDeliveryAuthorization: currentAuthorization?.authorization,
        trustedDeviceCredential: try trustedDeviceCredential(session.trustedDeviceId),
        trustedDeviceId: session.trustedDeviceId
      ),
      identityToken: session.identityToken
    )
    try scheduledDeliveryAuthorizationStore.save(
      authorization,
      trustedDeviceId: session.trustedDeviceId
    )
    return authorization
  }

  func claimScheduledSend(
    scheduleId: UUID,
    revision: Int,
    trustedDeviceId: String
  ) async throws -> ScheduledSendClaimResult {
    let response: ScheduledSendClaimWireResponse = try await performScheduledDeliveryMutation(
      path: "scheduledSend:claim",
      args: ClaimScheduledSendArgs(
        revision: revision,
        scheduleId: scheduleId.uuidString.lowercased(),
        scheduledDeliveryAuthorization:
          try scheduledDeliveryAuthorization(trustedDeviceId).authorization,
        trustedDeviceId: trustedDeviceId
      )
    )
    return try response.result()
  }

  func advanceScheduledSendClaimToHandoff(
    scheduleId: UUID,
    revision: Int,
    claimGeneration: Int,
    trustedDeviceId: String
  ) async throws -> Bool {
    try await performScheduledDeliveryMutation(
      path: "scheduledSend:advanceClaimToHandoff",
      args: try scheduledSendClaimArgs(
        scheduleId: scheduleId,
        revision: revision,
        claimGeneration: claimGeneration,
        trustedDeviceId: trustedDeviceId
      )
    )
  }

  func revalidateScheduledSendClaim(
    scheduleId: UUID,
    revision: Int,
    claimGeneration: Int,
    trustedDeviceId: String
  ) async throws -> ScheduledSendClaimResult {
    let response: ScheduledSendClaimWireResponse = try await performScheduledDeliveryQuery(
      path: "scheduledSend:revalidateClaim",
      args: try scheduledSendClaimArgs(
        scheduleId: scheduleId,
        revision: revision,
        claimGeneration: claimGeneration,
        trustedDeviceId: trustedDeviceId
      )
    )
    return try response.result()
  }

  func releaseScheduledSendClaim(
    scheduleId: UUID,
    revision: Int,
    claimGeneration: Int,
    trustedDeviceId: String
  ) async throws -> Bool {
    try await performScheduledDeliveryMutation(
      path: "scheduledSend:releaseClaim",
      args: try scheduledSendClaimArgs(
        scheduleId: scheduleId,
        revision: revision,
        claimGeneration: claimGeneration,
        trustedDeviceId: trustedDeviceId
      )
    )
  }

  func completeScheduledSendClaim(
    scheduleId: UUID,
    revision: Int,
    claimGeneration: Int,
    state: ScheduledSendCompletionState,
    trustedDeviceId: String
  ) async throws -> Bool {
    let authorization = try scheduledDeliveryAuthorization(trustedDeviceId)
    return try await performScheduledDeliveryMutation(
      path: "scheduledSend:complete",
      args: CompleteScheduledSendClaimArgs(
        claimGeneration: claimGeneration,
        revision: revision,
        scheduleId: scheduleId.uuidString.lowercased(),
        scheduledDeliveryAuthorization: authorization.authorization,
        state: state,
        trustedDeviceId: trustedDeviceId
      )
    )
  }

  private func scheduledSendClaimArgs(
    scheduleId: UUID,
    revision: Int,
    claimGeneration: Int,
    trustedDeviceId: String
  ) throws -> ScheduledSendClaimMutationArgs {
    ScheduledSendClaimMutationArgs(
      claimGeneration: claimGeneration,
      revision: revision,
      scheduleId: scheduleId.uuidString.lowercased(),
      scheduledDeliveryAuthorization:
        try scheduledDeliveryAuthorization(trustedDeviceId).authorization,
      trustedDeviceId: trustedDeviceId
    )
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

  private func performHTTPAction<Response: Decodable>(
    path: String,
    args: some Encodable,
    identityToken: String
  ) async throws -> Response {
    guard let convexSiteURL else {
      throw ConvexClientError.missingConvexURL
    }
    guard convexSiteURL.scheme?.lowercased() == "https" else {
      throw ConvexClientError.insecureConvexURL
    }

    var request = URLRequest(url: convexSiteURL.appending(path: path))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(identityToken)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONEncoder().encode(args)

    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw ConvexClientError.decodeError
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
      if let errorData = try? JSONDecoder().decode(
        ConvexFunctionErrorData.self,
        from: data
      ), let code = errorData.code {
        throw ConvexClientError.convexApplicationFailure(
          status: "error",
          code: code,
          message: nil
        )
      }
      let message = String(data: data, encoding: .utf8)
      throw ConvexClientError.httpActionError(
        statusCode: httpResponse.statusCode,
        message: message
      )
    }

    return try JSONDecoder().decode(Response.self, from: data)
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

  private func performScheduledDeliveryMutation<Response: Decodable>(
    path: String,
    args: some Encodable
  ) async throws -> Response {
    guard convexURL?.scheme?.lowercased() == "https" else {
      throw ConvexClientError.insecureConvexURL
    }
    return try await performRequest(
      endpoint: "api/mutation",
      path: path,
      args: args,
      identityToken: nil
    )
  }

  private func performScheduledDeliveryQuery<Response: Decodable>(
    path: String,
    args: some Encodable
  ) async throws -> Response {
    guard convexURL?.scheme?.lowercased() == "https" else {
      throw ConvexClientError.insecureConvexURL
    }
    return try await performRequest(
      endpoint: "api/query",
      path: path,
      args: args,
      identityToken: nil
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
    if identityToken != nil, convexURL.scheme?.lowercased() != "https" {
      throw ConvexClientError.insecureConvexURL
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
      throw failure(for: functionResponse)
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
    if identityToken != nil, convexURL.scheme?.lowercased() != "https" {
      throw ConvexClientError.insecureConvexURL
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
      throw failure(for: functionResponse)
    }

    return functionResponse.value
  }

  private func failure<Value>(
    for envelope: ConvexFunctionEnvelope<Value>
  ) -> ConvexClientError {
    if let code = envelope.errorData?.code {
      return .convexApplicationFailure(
        status: envelope.status,
        code: code,
        message: envelope.errorMessage
      )
    }
    return .convexFailure(status: envelope.status, message: envelope.errorMessage)
  }
}

private struct EmptyConvexArgs: Encodable {}

private struct ConnectProductAccountArgs: Encodable {
  let deviceIdentifier: String
  let deviceName: String
  let platform: String
  let supportsDeviceCredentials: Bool
  let trustedDeviceCredential: String?
}

private struct ListTrustedDevicesArgs: Encodable {
  let trustedDeviceCredential: String?
  let trustedDeviceId: String
}

private struct RenameTrustedDeviceArgs: Encodable {
  let displayName: String
  let trustedDeviceCredential: String?
  let trustedDeviceId: String
  let trustedDeviceToRenameId: String
}

private struct UnregisterTrustedDeviceArgs: Encodable {
  let deviceIdentifier: String
  let trustedDeviceCredential: String?
  let trustedDeviceId: String
}

private struct RevokeTrustedDeviceArgs: Encodable {
  let encryptedTransition: ProductSyncEncryptedPayload
  let expectedRecoveryUpdatedAt: Int64
  let recoveryWrappedAccountKey: ProductSyncEncryptedPayload
  let trustedDeviceCredential: String?
  let trustedDeviceId: String
  let trustedDeviceToRevokeId: String
}

private struct ProductSyncKeyRotationArgs: Encodable {
  let trustedDeviceCredential: String?
  let trustedDeviceId: String
}

private struct AcknowledgeProductSyncKeyRotationArgs: Encodable {
  let keyEpoch: Int
  let trustedDeviceCredential: String?
  let trustedDeviceId: String
}

private struct DeleteProductAccountArgs: Encodable {
  let authorizationCode: String
  let trustedDeviceCredential: String?
  let trustedDeviceId: String
}

private struct RegisterGmailConnectionArgs: Encodable {
  let gmailIdentityToken: String
  let opaqueConnectionId: String
  let trustedDeviceCredential: String?
  let trustedDeviceId: String
}

private struct RegisterDevicePushArgs: Encodable {
  let apnsEnvironment: String
  let apnsToken: String
  let trustedDeviceCredential: String?
  let trustedDeviceId: String
}

private struct ShouldStopGmailPushWatchArgs: Encodable {
  let opaqueConnectionId: String
  let trustedDeviceCredential: String?
  let trustedDeviceId: String
}

private struct RemoveGmailProviderConnectionArgs: Encodable {
  let opaqueConnectionId: String
  let trustedDeviceCredential: String?
  let trustedDeviceId: String
}

private struct RemoveGmailProviderConnectionResponse: Decodable {
  let hasRemainingGmailConnections: Bool
  let removed: Bool
}

private struct UnregisterDevicePushArgs: Encodable {
  let trustedDeviceCredential: String?
  let trustedDeviceId: String
}

private struct VerifyGmailPushWatchArgs: Encodable {
  let gmailIdentityToken: String
  let historyId: String
  let opaqueConnectionId: String
  let trustedDeviceCredential: String?
  let trustedDeviceId: String
}

private struct PrepareMicrosoftGraphPushRouteArgs: Encodable {
  let clientStateDigest: String
  let opaqueConnectionId: String
  let trustedDeviceCredential: String?
  let trustedDeviceId: String
}

private struct ConfirmMicrosoftGraphPushRouteArgs: Encodable {
  let clientStateDigest: String?
  let expiresAt: Int64
  let routeId: String
  let subscriptionId: String
  let trustedDeviceCredential: String?
  let trustedDeviceId: String
}

private struct RollbackMicrosoftGraphPushRouteArgs: Encodable {
  let clientStateDigest: String
  let routeId: String
  let trustedDeviceCredential: String?
  let trustedDeviceId: String
}

private struct RollbackMicrosoftGraphPushRouteResponse: Decodable {
  let rolledBack: Bool
}

private struct RemoveMicrosoftGraphPushRouteArgs: Encodable {
  let opaqueConnectionId: String
  let trustedDeviceCredential: String?
  let trustedDeviceId: String
}

private struct RemoveMicrosoftGraphPushRouteResponse: Decodable {
  let removed: Bool
}

private struct PutEncryptedPayloadIfUnchangedArgs: Encodable {
  let encryptedPayload: ProductSyncEncryptedPayload
  let expectedUpdatedAt: Int64?
  let payloadIdentifier: String
  let trustedDeviceCredential: String?
  let trustedDeviceId: String
}

private struct AtomicPayloadRevisionArgs: Encodable {
  let expectedUpdatedAt: Int64
  let payloadIdentifier: String

  init(_ check: ProductSyncAtomicCheck) {
    expectedUpdatedAt = check.expectedUpdatedAt
    payloadIdentifier = check.payloadIdentifier
  }

  init(_ deletion: ProductSyncAtomicDelete) {
    expectedUpdatedAt = deletion.expectedUpdatedAt
    payloadIdentifier = deletion.payloadIdentifier
  }
}

private struct AtomicPayloadWriteArgs: Encodable {
  let encryptedPayload: ProductSyncEncryptedPayload
  let expectedUpdatedAt: Int64?
  let payloadIdentifier: String

  init(_ write: ProductSyncAtomicWrite) {
    encryptedPayload = write.encryptedPayload
    expectedUpdatedAt = write.expectedUpdatedAt
    payloadIdentifier = write.payloadIdentifier
  }
}

private struct PutEncryptedPayloadsAtomicallyArgs: Encodable {
  let checks: [AtomicPayloadRevisionArgs]
  let deletes: [AtomicPayloadRevisionArgs]
  let trustedDeviceCredential: String?
  let trustedDeviceId: String
  let writes: [AtomicPayloadWriteArgs]
}

private struct PutEncryptedPayloadsAtomicallyResponse: Decodable {
  let committed: Bool
  let payloads: [EncryptedProductSyncPayload]
}

private struct ReplaceRecoveryMaterialIfUnchangedArgs: Encodable {
  let encryptedPayload: ProductSyncEncryptedPayload
  let expectedUpdatedAt: Int64?
  let trustedDeviceCredential: String?
  let trustedDeviceId: String
}

private struct GetEncryptedProductSyncPayloadArgs: Encodable {
  let payloadIdentifier: String
  let trustedDeviceCredential: String?
  let trustedDeviceId: String
}

private struct GetEncryptedProductSyncPayloadsArgs: Encodable {
  let payloadIdentifiers: [String]
  let trustedDeviceCredential: String?
  let trustedDeviceId: String
}

private struct MarkProductSyncMaterialInitializedArgs: Encodable {
  let trustedDeviceCredential: String?
  let trustedDeviceId: String
}

private struct ListEncryptedProductSyncPayloadsArgs: Encodable {
  let paginationOpts: ConvexPaginationOptions
  let payloadIdentifierPrefix: String?
  let trustedDeviceCredential: String?
  let trustedDeviceId: String
}

private struct AdmitScheduledSendArgs: Encodable {
  let deadlineAt: Int64
  let dueAt: Int64
  let encryptedPayloadIdentifier: String
  let encryptedPayloadUpdatedAt: Int64
  let revision: Int
  let scheduleId: String
  let trustedDeviceCredential: String?
  let trustedDeviceId: String
}

private struct CancelScheduledSendArgs: Encodable {
  let editGeneration: Int?
  let revision: Int
  let scheduleId: String
  let trustedDeviceCredential: String?
  let trustedDeviceId: String
}

private struct ScheduledSendStatusArgs: Encodable {
  let scheduleId: String
  let trustedDeviceCredential: String?
  let trustedDeviceId: String
}

private struct BeginScheduledSendEditArgs: Encodable {
  let revision: Int
  let scheduleId: String
  let trustedDeviceCredential: String?
  let trustedDeviceId: String
}

private struct ReleaseScheduledSendEditArgs: Encodable {
  let editGeneration: Int
  let revision: Int
  let scheduleId: String
  let trustedDeviceCredential: String?
  let trustedDeviceId: String
}

private struct ReplaceScheduledSendArgs: Encodable {
  let deadlineAt: Int64
  let dueAt: Int64
  let editGeneration: Int
  let encryptedPayloadIdentifier: String
  let encryptedPayloadUpdatedAt: Int64
  let expectedRevision: Int
  let requestedAt: Int64?
  let revision: Int
  let scheduleId: String
  let trustedDeviceCredential: String?
  let trustedDeviceId: String
}

private struct RegisterScheduledDeliveryCapabilityArgs: Encodable {
  let capabilityVersion: Int
  let scheduledDeliveryAuthorization: String?
  let trustedDeviceCredential: String?
  let trustedDeviceId: String
}

private struct ClaimScheduledSendArgs: Encodable {
  let revision: Int
  let scheduleId: String
  let scheduledDeliveryAuthorization: String
  let trustedDeviceId: String
}

private struct ScheduledSendClaimMutationArgs: Encodable {
  let claimGeneration: Int
  let revision: Int
  let scheduleId: String
  let scheduledDeliveryAuthorization: String
  let trustedDeviceId: String
}

private struct CompleteScheduledSendClaimArgs: Encodable {
  let claimGeneration: Int
  let revision: Int
  let scheduleId: String
  let scheduledDeliveryAuthorization: String
  let state: ScheduledSendCompletionState
  let trustedDeviceId: String
}

private struct ScheduledSendClaimWireResponse: Decodable {
  let authorizationGeneration: Int?
  let expiresAt: Int64?
  let generation: Int?
  let phase: ScheduledSendClaimPhase?
  let status: Status

  enum Status: String, Decodable {
    case claimed
    case unavailable
  }

  func result() throws -> ScheduledSendClaimResult {
    switch status {
    case .unavailable:
      return .unavailable
    case .claimed:
      guard let authorizationGeneration, let generation, let phase else {
        throw ConvexClientError.decodeError
      }
      return .claimed(
        ScheduledSendClaim(
          authorizationGeneration: authorizationGeneration,
          expiresAt: expiresAt,
          generation: generation,
          phase: phase
        )
      )
    }
  }
}

private struct ScheduledSendEditLeaseWireResponse: Decodable {
  let expiresAt: Int64?
  let generation: Int?
  let status: Status

  enum Status: String, Decodable {
    case acquired
    case unavailable
  }

  func result() throws -> ScheduledSendEditLeaseResult {
    switch status {
    case .unavailable:
      return .unavailable
    case .acquired:
      guard let expiresAt, let generation else { throw ConvexClientError.decodeError }
      return .acquired(ScheduledSendEditLease(expiresAt: expiresAt, generation: generation))
    }
  }
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
  let errorData: ConvexFunctionErrorData?
}

private struct ConvexFunctionErrorData: Decodable {
  let code: String?

  private enum CodingKeys: String, CodingKey {
    case code
  }

  init(from decoder: Decoder) throws {
    guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
      code = nil
      return
    }
    code = try container.decodeIfPresent(String.self, forKey: .code)
  }
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
      protocolClass: URLProtocolStub.Type = URLProtocolStub.self,
      stubbing handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    )
      -> URLSession
    {
      URLProtocolStub.setRequestHandler(handler, for: protocolClass)
      let configuration = URLSessionConfiguration.ephemeral
      configuration.protocolClasses = [protocolClass]
      return URLSession(configuration: configuration)
    }
  }

  class URLProtocolStub: URLProtocol {
    fileprivate typealias RequestHandler = (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let requestHandlerLock = NSLock()
    private static var requestHandlers: [ObjectIdentifier: RequestHandler] = [:]

    fileprivate static func setRequestHandler(
      _ handler: @escaping RequestHandler,
      for protocolClass: URLProtocolStub.Type
    ) {
      requestHandlerLock.withLock {
        requestHandlers[ObjectIdentifier(protocolClass)] = handler
      }
    }

    private static func requestHandler(
      for protocolClass: URLProtocolStub.Type
    ) -> RequestHandler? {
      requestHandlerLock.withLock {
        requestHandlers[ObjectIdentifier(protocolClass)]
      }
    }

    override static func canInit(with request: URLRequest) -> Bool {
      true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
      request
    }

    override func startLoading() {
      guard let handler = Self.requestHandler(for: type(of: self)) else {
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
