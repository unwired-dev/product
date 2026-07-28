import Foundation
import XCTest

@testable import unwired_mail

// swiftlint:disable file_length type_body_length
final class MailboxConnectionSyncServiceTests: XCTestCase {
  private let firstDeviceSession = ProductAccountSessionSnapshot(
    appleUserIdentifier: "apple-user-001",
    identityToken: "first-device-token",
    productAccountId: "product-account-001",
    trustedDeviceId: "trusted-device-001"
  )
  private let secondDeviceSession = ProductAccountSessionSnapshot(
    appleUserIdentifier: "apple-user-001",
    identityToken: "second-device-token",
    productAccountId: "product-account-001",
    trustedDeviceId: "trusted-device-002"
  )

  func testConnectionCreatedOnOneDeviceAppearsOnAnotherWithoutAuthorization() async throws {
    let services = try makeServices()

    _ = try await services.firstDevice.saveConnection(
      Self.connection,
      session: firstDeviceSession
    )
    let secondDeviceSnapshot = try await services.secondDevice.loadSnapshot(
      session: secondDeviceSession
    )

    XCTAssertEqual(secondDeviceSnapshot.connections, [Self.connection.definition])
    XCTAssertNil(secondDeviceSnapshot.defaultSendingConnectionId)
  }

  func testGenericMailDefinitionSynchronizesWithoutDeviceCredential() async throws {
    let services = try makeServices()
    let definition = Self.genericMailDefinition.synchronizedDefinition(
      connectedAt: 1_781_200_000_600
    )

    _ = try await services.firstDevice.saveDefinition(
      definition,
      session: firstDeviceSession
    )
    let secondDeviceSnapshot = try await services.secondDevice.loadSnapshot(
      session: secondDeviceSession
    )

    XCTAssertEqual(
      secondDeviceSnapshot.connections.first?.genericMailDefinition,
      Self.genericMailDefinition
    )
    let encryptedPayload = try XCTUnwrap(services.transport.payload?.encryptedPayload)
    XCTAssertFalse(encryptedPayload.ciphertextBase64.contains("imap.example.com"))
    XCTAssertFalse(encryptedPayload.ciphertextBase64.contains("reader@example.com"))
  }

  func testGenericDefinitionsWithSameAddressAndDifferentEndpointsRemainDistinct() async throws {
    let services = try makeServices()
    let otherEndpointDefinition = GenericMailConnectionDefinition(
      authorizationMethod: .password,
      emailAddress: Self.genericMailDefinition.emailAddress,
      incomingEndpoint: GenericMailEndpoint(
        mailProtocol: .imap,
        hostname: "imap.other.example",
        port: 993,
        security: .implicitTLS
      ),
      outgoingEndpoint: GenericMailEndpoint(
        mailProtocol: .smtp,
        hostname: "smtp.other.example",
        port: 465,
        security: .implicitTLS
      ),
      roleMappings: [.sent: "Sent"],
      username: Self.genericMailDefinition.username
    )

    _ = try await services.firstDevice.saveDefinition(
      Self.genericMailDefinition.synchronizedDefinition(connectedAt: 1),
      session: firstDeviceSession
    )
    let snapshot = try await services.firstDevice.saveDefinition(
      otherEndpointDefinition.synchronizedDefinition(connectedAt: 2),
      session: firstDeviceSession
    )

    XCTAssertNotEqual(Self.genericMailDefinition.connectionId, otherEndpointDefinition.connectionId)
    XCTAssertEqual(snapshot.connections.count, 2)
  }

  func testDefaultSendingConnectionSynchronizesWithoutChoosingAnotherConnection() async throws {
    let services = try makeServices()
    _ = try await services.firstDevice.saveConnection(
      Self.connection,
      session: firstDeviceSession
    )
    _ = try await services.firstDevice.saveConnection(
      Self.otherConnection,
      session: firstDeviceSession
    )

    _ = try await services.firstDevice.setDefaultSendingConnection(
      Self.connection.id,
      session: firstDeviceSession
    )
    let secondDeviceSnapshot = try await services.secondDevice.loadSnapshot(
      session: secondDeviceSession
    )

    XCTAssertEqual(secondDeviceSnapshot.defaultSendingConnectionId, Self.connection.id)
    XCTAssertNotEqual(secondDeviceSnapshot.defaultSendingConnectionId, Self.otherConnection.id)
  }

  func testRemovalTombstonePreventsAnOfflineDeviceFromResurrectingAConnection() async throws {
    let services = try makeServices()
    _ = try await services.firstDevice.saveConnection(
      Self.connection,
      session: firstDeviceSession
    )
    let offlineSnapshot = try await services.secondDevice.loadSnapshot(
      session: secondDeviceSession
    )
    let offlineConnection = try XCTUnwrap(offlineSnapshot.connections.first)

    _ = try await services.firstDevice.removeConnection(
      Self.connection.id,
      session: firstDeviceSession
    )
    _ = try await services.secondDevice.reconcileConnections(
      [offlineConnection],
      session: secondDeviceSession
    )
    let convergedSnapshot = try await services.firstDevice.loadSnapshot(
      session: firstDeviceSession
    )

    XCTAssertTrue(convergedSnapshot.connections.isEmpty)
    XCTAssertEqual(convergedSnapshot.removedConnectionIds, [Self.connection.id])
  }

  func testReaddedConnectionAdvancesGenerationBeforeOfflineDeviceReconciles() async throws {
    let services = try makeServices()
    let originalSnapshot = try await services.firstDevice.saveConnection(
      Self.connection,
      session: firstDeviceSession
    )
    let offlineDefinition = try XCTUnwrap(originalSnapshot.connections.first)

    _ = try await services.firstDevice.removeConnection(
      Self.connection.id,
      session: firstDeviceSession
    )
    let recreatedSnapshot = try await services.firstDevice.saveConnection(
      Self.connection,
      session: firstDeviceSession
    )
    _ = try await services.secondDevice.reconcileConnections(
      [offlineDefinition],
      session: secondDeviceSession
    )
    let convergedSnapshot = try await services.firstDevice.loadSnapshot(
      session: firstDeviceSession
    )

    XCTAssertEqual(offlineDefinition.authorizationGeneration, 0)
    XCTAssertEqual(recreatedSnapshot.connections.first?.authorizationGeneration, 1)
    XCTAssertEqual(convergedSnapshot.connections.first?.authorizationGeneration, 1)
    XCTAssertTrue(convergedSnapshot.removedConnectionIds.isEmpty)
  }

  func testLegacyWriterCannotResetRetainedAuthorizationGeneration() async throws {
    let services = try makeServices()
    _ = try await services.firstDevice.saveConnection(
      Self.connection,
      session: firstDeviceSession
    )
    _ = try await services.firstDevice.removeConnection(
      Self.connection.id,
      session: firstDeviceSession
    )
    _ = try await services.firstDevice.saveConnection(
      Self.connection,
      session: firstDeviceSession
    )
    let definition = Self.connection.definition
    let legacyPayload: [String: Any] = [
      "connections": [
        [
          "connectedAt": definition.connectedAt,
          "displayName": definition.displayName,
          "provider": definition.provider,
          "providerAccountIdentifier": definition.providerAccountIdentifier,
          "stableProviderConnectionKey": definition.stableProviderConnectionKey,
        ]
      ],
      "removals": [],
      "schemaVersion": 1,
    ]
    let encryptedLegacyPayload = try services.keyMaterial.encryptPayload(
      JSONSerialization.data(withJSONObject: legacyPayload),
      associatedData: Data("mailbox-connections-primary".utf8)
    )
    _ = try await services.transport.putEncryptedProductSyncPayload(
      identityToken: secondDeviceSession.identityToken,
      payloadIdentifier: "mailbox-connections-primary",
      encryptedPayload: encryptedLegacyPayload,
      trustedDeviceId: secondDeviceSession.trustedDeviceId
    )

    let snapshot = try await services.firstDevice.loadSnapshot(session: firstDeviceSession)
    services.transport.loadError = MailboxConnectionSyncTestError.unavailable
    let offlineSnapshot = try await services.firstDevice.loadSnapshotForProviderAccess(
      session: firstDeviceSession
    )

    XCTAssertEqual(snapshot.connections.first?.authorizationGeneration, 1)
    XCTAssertEqual(offlineSnapshot.connections.first?.authorizationGeneration, 1)
    XCTAssertTrue(snapshot.removedConnectionIds.isEmpty)
  }

  func testRemovingDefaultConnectionClearsDefaultWithoutSubstitution() async throws {
    let services = try makeServices()
    _ = try await services.firstDevice.saveConnection(
      Self.connection,
      session: firstDeviceSession
    )
    _ = try await services.firstDevice.saveConnection(
      Self.otherConnection,
      session: firstDeviceSession
    )
    _ = try await services.firstDevice.setDefaultSendingConnection(
      Self.connection.id,
      session: firstDeviceSession
    )

    let snapshot = try await services.firstDevice.removeConnection(
      Self.connection.id,
      session: firstDeviceSession
    )

    XCTAssertNil(snapshot.defaultSendingConnectionId)
    XCTAssertEqual(snapshot.connections, [Self.otherConnection.definition])
  }

  func testMailboxDefinitionIsOpaqueToProductSyncTransport() async throws {
    let services = try makeServices()

    _ = try await services.firstDevice.saveConnection(
      Self.connection,
      session: firstDeviceSession
    )

    let writtenPayload = try XCTUnwrap(services.transport.payload)
    XCTAssertEqual(writtenPayload.payloadIdentifier, "mailbox-connections-primary")
    XCTAssertFalse(writtenPayload.encryptedPayload.ciphertextBase64.contains("user@example.com"))
    XCTAssertFalse(writtenPayload.encryptedPayload.ciphertextBase64.contains("gmail-user-001"))
  }

  func testProviderAccessUsesLastEncryptedSnapshotWhenProductSyncIsTemporarilyUnavailable()
    async throws
  {
    let services = try makeServices()
    _ = try await services.firstDevice.saveConnection(
      Self.connection,
      session: firstDeviceSession
    )
    _ = try await services.secondDevice.loadSnapshot(session: secondDeviceSession)
    services.transport.loadError = MailboxConnectionSyncTestError.unavailable

    let snapshot = try await services.secondDevice.loadSnapshotForProviderAccess(
      session: secondDeviceSession
    )

    XCTAssertEqual(snapshot.connections, [Self.connection.definition])
  }

  private func makeServices() throws -> Services {
    let keyMaterial = try ProductSyncKeyMaterial.create(
      accountKeyData: Data(repeating: 7, count: ProductSyncKeyMaterial.keyByteCount),
      recoveryKeyData: Data(repeating: 8, count: ProductSyncKeyMaterial.keyByteCount)
    )
    let firstStore = InMemoryProductSyncKeyMaterialStore()
    let secondStore = InMemoryProductSyncKeyMaterialStore()
    try firstStore.save(keyMaterial, productAccountId: firstDeviceSession.productAccountId)
    try secondStore.save(keyMaterial, productAccountId: secondDeviceSession.productAccountId)
    let transport = RecordingMailboxConnectionSyncTransport()
    return Services(
      firstDevice: MailboxConnectionSyncService(
        cacheStore: InMemoryMailboxConnectionSyncCacheStore(),
        keyMaterialStore: firstStore,
        transport: transport
      ),
      keyMaterial: keyMaterial,
      secondDevice: MailboxConnectionSyncService(
        cacheStore: InMemoryMailboxConnectionSyncCacheStore(),
        keyMaterialStore: secondStore,
        transport: transport
      ),
      transport: transport
    )
  }

  private struct Services {
    let firstDevice: MailboxConnectionSyncService
    let keyMaterial: ProductSyncKeyMaterial
    let secondDevice: MailboxConnectionSyncService
    let transport: RecordingMailboxConnectionSyncTransport
  }

  private static let connection = GmailProviderConnectionStatus(
    connectedAt: 1_781_200_000_000,
    emailAddress: "user@example.com",
    lastVerifiedAt: 1_781_200_000_100,
    provider: "gmail",
    providerAccountIdentifier: "gmail-user-001",
    trustedDeviceId: "trusted-device-001",
    updatedAt: 1_781_200_000_200
  ).mailboxConnection(productAccountId: "product-account-001", authorizationState: .authorized)

  private static let otherConnection = GmailProviderConnectionStatus(
    connectedAt: 1_781_200_000_300,
    emailAddress: "other@example.com",
    lastVerifiedAt: 1_781_200_000_400,
    provider: "gmail",
    providerAccountIdentifier: "gmail-user-002",
    trustedDeviceId: "trusted-device-001",
    updatedAt: 1_781_200_000_500
  ).mailboxConnection(productAccountId: "product-account-001", authorizationState: .authorized)

  private static let genericMailDefinition = GenericMailConnectionDefinition(
    authorizationMethod: .password,
    emailAddress: "reader@example.com",
    incomingEndpoint: GenericMailEndpoint(
      mailProtocol: .imap,
      hostname: "imap.example.com",
      port: 993,
      security: .implicitTLS
    ),
    outgoingEndpoint: GenericMailEndpoint(
      mailProtocol: .smtp,
      hostname: "smtp.example.com",
      port: 465,
      security: .implicitTLS
    ),
    roleMappings: [.sent: "Sent"],
    username: "reader@example.com"
  )
  func testFirstMailboxWriteRejectsMissingKeyWhenAnotherProductSyncPayloadExists()
    async throws
  {
    let keyMaterialStore = InMemoryProductSyncKeyMaterialStore()
    let transport = RecordingMailboxConnectionSyncTransport()
    transport.additionalPayloads = [
      EncryptedProductSyncPayload(
        encryptedPayload: ProductSyncEncryptedPayload(
          algorithm: ProductSyncEncryptedPayload.algorithmName,
          ciphertextBase64: "ciphertext",
          keyVersion: 1,
          nonceBase64: "nonce",
          schemaVersion: 1,
          tagBase64: "tag"
        ),
        payloadIdentifier: "custom-categories-primary",
        updatedAt: 1
      )
    ]
    let service = MailboxConnectionSyncService(
      cacheStore: InMemoryMailboxConnectionSyncCacheStore(),
      keyMaterialStore: keyMaterialStore,
      transport: transport
    )

    do {
      _ = try await service.saveConnection(Self.connection, session: firstDeviceSession)
      XCTFail("Expected the missing Product Sync key to prevent a new mailbox write")
    } catch let error as MailboxConnectionSyncError {
      XCTAssertEqual(error, .missingProductSyncKeyMaterial)
    }
    XCTAssertNil(transport.payload)
  }
}
// swiftlint:enable type_body_length

private final class RecordingMailboxConnectionSyncTransport: ProductSyncPayloadTransport {
  var additionalPayloads: [EncryptedProductSyncPayload] = []
  var loadError: Error?
  var payload: EncryptedProductSyncPayload? {
    payloads["mailbox-connections-primary"]
  }
  private var payloads: [String: EncryptedProductSyncPayload] = [:]
  private var updatedAt: Int64 = 1_781_200_000_000

  func listEncryptedProductSyncPayloads(
    identityToken _: String,
    payloadIdentifierPrefix _: String?
  ) async throws -> [EncryptedProductSyncPayload] {
    additionalPayloads + payloads.values
  }

  func getEncryptedProductSyncPayload(
    identityToken _: String,
    payloadIdentifier: String
  ) async throws -> EncryptedProductSyncPayload? {
    if let loadError { throw loadError }
    return payloads[payloadIdentifier]
  }

  func getEncryptedProductSyncPayloads(
    identityToken _: String,
    payloadIdentifiers: [String]
  ) async throws -> [EncryptedProductSyncPayload] {
    payloadIdentifiers.compactMap { payloads[$0] }
  }

  func putEncryptedProductSyncPayload(
    identityToken _: String,
    payloadIdentifier: String,
    encryptedPayload: ProductSyncEncryptedPayload,
    trustedDeviceId _: String
  ) async throws -> EncryptedProductSyncPayload {
    write(payloadIdentifier: payloadIdentifier, encryptedPayload: encryptedPayload)
  }

  func putEncryptedProductSyncPayloadIfAbsent(
    identityToken _: String,
    payloadIdentifier: String,
    encryptedPayload: ProductSyncEncryptedPayload,
    trustedDeviceId _: String
  ) async throws -> EncryptedProductSyncPayload {
    payloads[payloadIdentifier]
      ?? write(payloadIdentifier: payloadIdentifier, encryptedPayload: encryptedPayload)
  }

  func putEncryptedProductSyncPayloadIfUnchanged(
    identityToken _: String,
    payloadIdentifier: String,
    encryptedPayload: ProductSyncEncryptedPayload,
    trustedDeviceId _: String,
    expectedUpdatedAt: Int64?
  ) async throws -> EncryptedProductSyncPayload {
    let existing = payloads[payloadIdentifier]
    guard existing?.updatedAt == expectedUpdatedAt else {
      return try XCTUnwrap(existing)
    }
    return write(payloadIdentifier: payloadIdentifier, encryptedPayload: encryptedPayload)
  }

  private func write(
    payloadIdentifier: String,
    encryptedPayload: ProductSyncEncryptedPayload
  ) -> EncryptedProductSyncPayload {
    updatedAt += 1
    let payload = EncryptedProductSyncPayload(
      encryptedPayload: encryptedPayload,
      payloadIdentifier: payloadIdentifier,
      updatedAt: updatedAt
    )
    payloads[payloadIdentifier] = payload
    return payload
  }
}

private enum MailboxConnectionSyncTestError: Error {
  case unavailable
}
