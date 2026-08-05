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
    let recreatedSnapshot = try await recreateConnection(
      using: services.firstDevice,
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
    XCTAssertEqual(
      convergedSnapshot.authorizationCleanupConnectionIds,
      [Self.connection.id]
    )
  }

  func testRemovalInvalidatesConcurrentReauthorization() async throws {
    let services = try makeServices()
    _ = try await services.firstDevice.saveConnection(
      Self.connection,
      session: firstDeviceSession
    )
    services.transport.afterGenerationFloorWrite = {
      _ = try await services.secondDevice.saveConnection(
        Self.connection,
        session: self.secondDeviceSession
      )
    }

    _ = try await services.firstDevice.removeConnection(
      Self.connection.id,
      session: firstDeviceSession
    )
    let recreatedSnapshot = try await recreateConnection(
      using: services.firstDevice,
      session: firstDeviceSession
    )

    XCTAssertEqual(recreatedSnapshot.connections.first?.authorizationGeneration, 1)
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
    _ = try await recreateConnection(
      using: services.firstDevice,
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

  // swiftlint:disable:next function_body_length
  func testLegacyRemovalGenerationIsRetainedBeforeReauthorizationClearsTombstone()
    async throws
  {
    let services = try makeServices()
    let definition = Self.connection.definition
    let legacyRemovalPayload: [String: Any] = [
      "connections": [],
      "removals": [
        [
          "provider": definition.provider,
          "providerAccountIdentifier": definition.providerAccountIdentifier,
          "removedAt": 1_781_200_000_300,
        ]
      ],
      "schemaVersion": 1,
    ]
    let encryptedRemovalPayload = try services.keyMaterial.encryptPayload(
      JSONSerialization.data(withJSONObject: legacyRemovalPayload),
      associatedData: Data("mailbox-connections-primary".utf8)
    )
    _ = try await services.transport.putEncryptedProductSyncPayload(
      identityToken: firstDeviceSession.identityToken,
      payloadIdentifier: "mailbox-connections-primary",
      encryptedPayload: encryptedRemovalPayload,
      trustedDeviceId: firstDeviceSession.trustedDeviceId
    )

    let recreated = try await recreateConnection(
      using: services.firstDevice,
      session: firstDeviceSession
    )
    let legacyDefinitionPayload: [String: Any] = [
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
    let encryptedDefinitionPayload = try services.keyMaterial.encryptPayload(
      JSONSerialization.data(withJSONObject: legacyDefinitionPayload),
      associatedData: Data("mailbox-connections-primary".utf8)
    )
    _ = try await services.transport.putEncryptedProductSyncPayload(
      identityToken: secondDeviceSession.identityToken,
      payloadIdentifier: "mailbox-connections-primary",
      encryptedPayload: encryptedDefinitionPayload,
      trustedDeviceId: secondDeviceSession.trustedDeviceId
    )

    let snapshot = try await services.firstDevice.loadSnapshot(session: firstDeviceSession)

    XCTAssertEqual(recreated.connections.first?.authorizationGeneration, 1)
    XCTAssertEqual(snapshot.connections.first?.authorizationGeneration, 1)
  }

  func testSecondLegacyRemovalAdvancesPastRetainedAuthorizationGeneration() async throws {
    let services = try makeServices()
    _ = try await services.firstDevice.saveConnection(
      Self.connection,
      session: firstDeviceSession
    )
    _ = try await services.firstDevice.removeConnection(
      Self.connection.id,
      session: firstDeviceSession
    )
    _ = try await recreateConnection(
      using: services.firstDevice,
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
      "removals": [
        [
          "provider": definition.provider,
          "providerAccountIdentifier": definition.providerAccountIdentifier,
          "removedAt": 1_781_200_000_700,
        ]
      ],
      "schemaVersion": 1,
    ]
    let encryptedPayload = try services.keyMaterial.encryptPayload(
      JSONSerialization.data(withJSONObject: legacyPayload),
      associatedData: Data("mailbox-connections-primary".utf8)
    )
    _ = try await services.transport.putEncryptedProductSyncPayload(
      identityToken: secondDeviceSession.identityToken,
      payloadIdentifier: "mailbox-connections-primary",
      encryptedPayload: encryptedPayload,
      trustedDeviceId: secondDeviceSession.trustedDeviceId
    )

    let snapshot = try await services.firstDevice.loadSnapshot(session: firstDeviceSession)

    XCTAssertEqual(snapshot.connections.first?.authorizationGeneration, 2)
    XCTAssertEqual(snapshot.authorizationCleanupConnectionIds, [Self.connection.id])
  }

  func testProviderAccessDoesNotDiscardFreshGenerationWhenIndividualLedgerLoadFails()
    async throws
  {
    let services = try makeServices()
    _ = try await services.firstDevice.saveConnection(
      Self.connection,
      session: firstDeviceSession
    )
    _ = try await services.secondDevice.loadSnapshot(session: secondDeviceSession)
    _ = try await services.firstDevice.removeConnection(
      Self.connection.id,
      session: firstDeviceSession
    )
    _ = try await recreateConnection(
      using: services.firstDevice,
      session: firstDeviceSession
    )
    _ = try await services.secondDevice.loadSnapshot(session: secondDeviceSession)
    services.transport.payloadLoadErrors["mailbox-authorization-generations-v1"] =
      MailboxConnectionSyncTestError.unavailable

    let snapshot = try await services.secondDevice.loadSnapshotForProviderAccess(
      session: secondDeviceSession
    )

    XCTAssertEqual(snapshot.connections.first?.authorizationGeneration, 1)
  }

  func testRetainedFloorDemotesStaleAuthorizationAndRequiresLocalCleanup()
    async throws
  {
    let services = try makeServices()
    _ = try await services.firstDevice.saveConnection(
      Self.connection,
      session: firstDeviceSession
    )
    _ = try await services.firstDevice.removeConnection(
      Self.connection.id,
      session: firstDeviceSession
    )
    let removedPayload = try XCTUnwrap(services.transport.payload)
    let plaintext = try services.keyMaterial.decryptPayload(
      removedPayload.encryptedPayload,
      associatedData: Data("mailbox-connections-primary".utf8)
    )
    var payload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: plaintext) as? [String: Any]
    )
    payload["connections"] = [
      try XCTUnwrap(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.connection.definition))
          as? [String: Any]
      )
    ]
    let encryptedPayload = try services.keyMaterial.encryptPayload(
      JSONSerialization.data(withJSONObject: payload),
      associatedData: Data("mailbox-connections-primary".utf8)
    )
    _ = try await services.transport.putEncryptedProductSyncPayload(
      identityToken: firstDeviceSession.identityToken,
      payloadIdentifier: "mailbox-connections-primary",
      encryptedPayload: encryptedPayload,
      trustedDeviceId: firstDeviceSession.trustedDeviceId
    )

    let retainedSnapshot = try await services.firstDevice.loadSnapshot(
      session: firstDeviceSession
    )
    let reauthorizedSnapshot = try await services.firstDevice.saveConnection(
      Self.connection,
      session: firstDeviceSession
    )

    XCTAssertEqual(retainedSnapshot.connections.count, 1)
    XCTAssertTrue(retainedSnapshot.removedConnectionIds.isEmpty)
    XCTAssertEqual(retainedSnapshot.authorizationCleanupConnectionIds, [Self.connection.id])
    XCTAssertTrue(reauthorizedSnapshot.removedConnectionIds.isEmpty)
    XCTAssertEqual(reauthorizedSnapshot.authorizationCleanupConnectionIds, [Self.connection.id])
  }

  func testReauthorizationKeepsLegacyVisibleTombstoneInPrimaryPayload() async throws {
    let services = try makeServices()
    _ = try await services.firstDevice.saveConnection(
      Self.connection,
      session: firstDeviceSession
    )
    _ = try await services.firstDevice.removeConnection(
      Self.connection.id,
      session: firstDeviceSession
    )

    let reauthorized = try await recreateConnection(
      using: services.firstDevice,
      session: firstDeviceSession
    )
    let remotePayload = try XCTUnwrap(services.transport.payload)
    let plaintext = try services.keyMaterial.decryptPayload(
      remotePayload.encryptedPayload,
      associatedData: Data("mailbox-connections-primary".utf8)
    )
    let payload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: plaintext) as? [String: Any]
    )
    let removals = try XCTUnwrap(payload["removals"] as? [[String: Any]])

    XCTAssertEqual(removals.count, 1)
    XCTAssertTrue(reauthorized.removedConnectionIds.isEmpty)
    XCTAssertEqual(
      reauthorized.authorizationCleanupConnectionIds,
      [Self.connection.id]
    )
  }

  func testUncommittedGenerationFloorDoesNotFenceAnActiveConnection() async throws {
    let services = try makeServices()
    _ = try await services.firstDevice.saveConnection(
      Self.connection,
      session: firstDeviceSession
    )
    services.transport.primaryWriteError = MailboxConnectionSyncTestError.unavailable

    do {
      _ = try await services.firstDevice.removeConnection(
        Self.connection.id,
        session: firstDeviceSession
      )
      XCTFail("Expected primary tombstone publication to fail")
    } catch MailboxConnectionSyncTestError.unavailable {
      // Expected.
    }
    services.transport.primaryWriteError = nil
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

    let snapshot = try await services.secondDevice.loadSnapshot(session: secondDeviceSession)

    XCTAssertEqual(snapshot.connections.first?.authorizationGeneration, 0)
    XCTAssertTrue(snapshot.removedConnectionIds.isEmpty)
  }

  func testAdvancingCommittedFloorBecomesPendingUntilSecondRemovalPublishes() async throws {
    let services = try makeServices()
    _ = try await services.firstDevice.saveConnection(
      Self.connection,
      session: firstDeviceSession
    )
    _ = try await services.firstDevice.removeConnection(
      Self.connection.id,
      session: firstDeviceSession
    )
    _ = try await recreateConnection(
      using: services.firstDevice,
      session: firstDeviceSession
    )
    services.transport.primaryWriteError = MailboxConnectionSyncTestError.unavailable

    do {
      _ = try await services.firstDevice.removeConnection(
        Self.connection.id,
        session: firstDeviceSession
      )
      XCTFail("Expected second tombstone publication to fail")
    } catch MailboxConnectionSyncTestError.unavailable {
      // Expected.
    }
    services.transport.primaryWriteError = nil
    var legacyDefinition = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.connection.definition))
        as? [String: Any]
    )
    legacyDefinition["authorizationGeneration"] = nil
    let legacyPayload: [String: Any] = [
      "connections": [legacyDefinition],
      "removals": [],
      "schemaVersion": 1,
    ]
    let encryptedLegacyPayload = try services.keyMaterial.encryptPayload(
      JSONSerialization.data(withJSONObject: legacyPayload),
      associatedData: Data("mailbox-connections-primary".utf8)
    )
    _ = try await services.transport.putEncryptedProductSyncPayload(
      identityToken: firstDeviceSession.identityToken,
      payloadIdentifier: "mailbox-connections-primary",
      encryptedPayload: encryptedLegacyPayload,
      trustedDeviceId: firstDeviceSession.trustedDeviceId
    )

    let snapshot = try await services.secondDevice.loadSnapshot(session: secondDeviceSession)

    XCTAssertEqual(snapshot.connections.first?.authorizationGeneration, 1)
    XCTAssertTrue(snapshot.removedConnectionIds.isEmpty)
  }

  func testRetryingPublishedRemovalCommitsItsPendingGenerationFloor() async throws {
    let services = try makeServices()
    _ = try await services.firstDevice.saveConnection(
      Self.connection,
      session: firstDeviceSession
    )
    services.transport.generationWriteError = MailboxConnectionSyncTestError.unavailable
    services.transport.generationWriteFailureCountdown = 3

    do {
      _ = try await services.firstDevice.removeConnection(
        Self.connection.id,
        session: firstDeviceSession
      )
      XCTFail("Expected generation-floor finalization to fail")
    } catch MailboxConnectionSyncTestError.unavailable {
      // Expected.
    }

    _ = try await services.firstDevice.removeConnection(
      Self.connection.id,
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

    let snapshot = try await services.secondDevice.loadSnapshot(session: secondDeviceSession)

    XCTAssertEqual(snapshot.connections.first?.authorizationGeneration, 1)
  }

  func testStaleRemovalFinalizerLeavesNewerGenerationFloorPending() async throws {
    let services = try makeServices()
    _ = try await services.firstDevice.saveConnection(
      Self.connection,
      session: firstDeviceSession
    )
    let finalizerGate = TestRendezvous()
    services.transport.beforeGenerationFloorWrite = { writeCount in
      if writeCount == 3 {
        await finalizerGate.hold()
      }
    }

    let firstRemoval = Task {
      try await services.firstDevice.removeConnection(
        Self.connection.id,
        session: self.firstDeviceSession
      )
    }
    await finalizerGate.waitUntilHeld()
    _ = try await recreateConnection(
      using: services.secondDevice,
      session: secondDeviceSession
    )
    services.transport.primaryWriteError = MailboxConnectionSyncTestError.unavailable
    do {
      _ = try await services.secondDevice.removeConnection(
        Self.connection.id,
        session: secondDeviceSession
      )
      XCTFail("Expected the newer removal publication to fail")
    } catch MailboxConnectionSyncTestError.unavailable {
      // Expected.
    }
    services.transport.primaryWriteError = nil
    await finalizerGate.release()
    _ = try await firstRemoval.value

    let snapshot = try await services.firstDevice.loadSnapshot(session: firstDeviceSession)

    XCTAssertEqual(snapshot.connections.first?.authorizationGeneration, 1)
  }

  func testActiveDefinitionCanBeRemovedWhenRetainedTombstoneSharesItsIdentity() async throws {
    let services = try makeServices()
    _ = try await services.firstDevice.saveConnection(
      Self.connection,
      session: firstDeviceSession
    )
    _ = try await services.firstDevice.removeConnection(
      Self.connection.id,
      session: firstDeviceSession
    )
    let removedPayload = try XCTUnwrap(services.transport.payload)
    let plaintext = try services.keyMaterial.decryptPayload(
      removedPayload.encryptedPayload,
      associatedData: Data("mailbox-connections-primary".utf8)
    )
    var payload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: plaintext) as? [String: Any]
    )
    payload["connections"] = [
      try XCTUnwrap(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.connection.definition))
          as? [String: Any]
      )
    ]
    payload["defaultSendingConnectionProvider"] = Self.connection.id.providerId.rawValue
    payload["defaultSendingProviderAccountIdentifier"] =
      Self.connection.id.providerMailboxIdentity.value
    let encryptedPayload = try services.keyMaterial.encryptPayload(
      JSONSerialization.data(withJSONObject: payload),
      associatedData: Data("mailbox-connections-primary".utf8)
    )
    _ = try await services.transport.putEncryptedProductSyncPayload(
      identityToken: firstDeviceSession.identityToken,
      payloadIdentifier: "mailbox-connections-primary",
      encryptedPayload: encryptedPayload,
      trustedDeviceId: firstDeviceSession.trustedDeviceId
    )

    let snapshot = try await services.firstDevice.removeConnection(
      Self.connection.id,
      session: firstDeviceSession
    )

    XCTAssertTrue(snapshot.connections.isEmpty)
    XCTAssertEqual(snapshot.removedConnectionIds, [Self.connection.id])
    XCTAssertNil(snapshot.defaultSendingConnectionId)
  }

  func testSavingAStaleDefinitionDoesNotClearItsRemovalTombstone() async throws {
    let services = try makeServices()
    _ = try await services.firstDevice.saveConnection(
      Self.connection,
      session: firstDeviceSession
    )
    let staleSnapshot = try await services.secondDevice.loadSnapshot(session: secondDeviceSession)
    let staleDefinition = try XCTUnwrap(staleSnapshot.connections.first)

    _ = try await services.firstDevice.removeConnection(
      Self.connection.id,
      session: firstDeviceSession
    )
    var observedRemoval: MailboxConnectionRemovalObservation?
    do {
      _ = try await services.secondDevice.saveDefinition(
        staleDefinition,
        session: secondDeviceSession
      )
      XCTFail("Expected the stale definition save to report the remote removal")
    } catch let error as MailboxConnectionSyncError {
      if case .connectionRemoved(let observation) = error {
        observedRemoval = observation
      } else {
        XCTFail("Unexpected Mailbox Connection sync error: \(error)")
      }
    }
    let snapshot = try await services.firstDevice.loadSnapshot(session: firstDeviceSession)

    XCTAssertTrue(snapshot.connections.isEmpty)
    XCTAssertEqual(snapshot.removedConnectionIds, [Self.connection.id])
    XCTAssertEqual(observedRemoval?.connectionId, Self.connection.id)
  }

  func testExplicitRecreationClearsTheRemovalTombstone() async throws {
    let services = try makeServices()
    _ = try await services.firstDevice.saveConnection(
      Self.connection,
      session: firstDeviceSession
    )
    _ = try await services.firstDevice.removeConnection(
      Self.connection.id,
      session: firstDeviceSession
    )

    let observation = try await observedRemoval(using: services.secondDevice)
    let snapshot = try await services.secondDevice.recreateDefinition(
      Self.connection.definition,
      after: observation,
      session: secondDeviceSession
    )

    XCTAssertEqual(
      snapshot.connections,
      [Self.connection.definition.withAuthorizationGeneration(1)]
    )
    XCTAssertTrue(snapshot.removedConnectionIds.isEmpty)
    XCTAssertEqual(snapshot.authorizationCleanupConnectionIds, [Self.connection.id])
  }

  func testRecreationRejectsARepeatedTombstoneWithTheSameRemovalTime() async throws {
    let services = try makeServices(clock: { 1_781_200_000_500 })
    _ = try await services.firstDevice.saveConnection(
      Self.connection,
      session: firstDeviceSession
    )
    _ = try await services.firstDevice.removeConnection(
      Self.connection.id,
      session: firstDeviceSession
    )
    let firstObservation = try await observedRemoval(using: services.secondDevice)
    _ = try await services.firstDevice.recreateDefinition(
      Self.connection.definition,
      after: firstObservation,
      session: firstDeviceSession
    )
    _ = try await services.firstDevice.removeConnection(
      Self.connection.id,
      session: firstDeviceSession
    )

    do {
      _ = try await services.secondDevice.recreateDefinition(
        Self.connection.definition,
        after: firstObservation,
        session: secondDeviceSession
      )
      XCTFail("Expected the stale observation to reject the repeated tombstone")
    } catch let error as MailboxConnectionSyncError {
      guard case .connectionRemoved(let currentObservation) = error else {
        return XCTFail("Unexpected Mailbox Connection sync error: \(error)")
      }
      XCTAssertEqual(currentObservation.removedAt, firstObservation.removedAt)
      XCTAssertNotEqual(
        currentObservation.tombstoneIdentifier,
        firstObservation.tombstoneIdentifier
      )
    }
  }

  func testRecreationRejectsAnObservationAfterAnotherDeviceAlreadyRecreated() async throws {
    let services = try makeServices()
    _ = try await services.firstDevice.saveConnection(
      Self.connection,
      session: firstDeviceSession
    )
    _ = try await services.firstDevice.removeConnection(
      Self.connection.id,
      session: firstDeviceSession
    )
    let observation = try await observedRemoval(using: services.secondDevice)
    _ = try await services.firstDevice.recreateDefinition(
      Self.connection.definition,
      after: observation,
      session: firstDeviceSession
    )

    do {
      _ = try await services.secondDevice.recreateDefinition(
        Self.connection.definition,
        after: observation,
        session: secondDeviceSession
      )
      XCTFail("Expected the stale recreation confirmation to be rejected")
    } catch let error as MailboxConnectionSyncError {
      XCTAssertEqual(error, .concurrentModification)
    }
  }

  func testRecreationIgnoresAnObservationForAnotherConnection() async throws {
    let services = try makeServices()
    _ = try await services.firstDevice.saveConnection(
      Self.connection,
      session: firstDeviceSession
    )
    _ = try await services.firstDevice.removeConnection(
      Self.connection.id,
      session: firstDeviceSession
    )
    let observation = try await observedRemoval(using: services.secondDevice)

    let snapshot = try await services.secondDevice.recreateDefinition(
      Self.otherConnection.definition,
      after: observation,
      session: secondDeviceSession
    )

    XCTAssertEqual(snapshot.connections, [Self.otherConnection.definition])
    XCTAssertEqual(snapshot.removedConnectionIds, [Self.connection.id])
  }

  func testRemovedDefinitionRefreshesProviderAccessCacheBeforeReportingRemoval() async throws {
    let services = try makeServices()
    _ = try await services.firstDevice.saveConnection(
      Self.connection,
      session: firstDeviceSession
    )
    _ = try await services.secondDevice.loadSnapshot(session: secondDeviceSession)
    _ = try await services.firstDevice.removeConnection(
      Self.connection.id,
      session: firstDeviceSession
    )

    do {
      _ = try await services.secondDevice.saveDefinition(
        Self.connection.definition,
        session: secondDeviceSession
      )
      XCTFail("Expected the stale definition save to report the removal")
    } catch let error as MailboxConnectionSyncError {
      guard case .connectionRemoved = error else {
        return XCTFail("Unexpected Mailbox Connection sync error: \(error)")
      }
    }
    services.transport.loadError = MailboxConnectionSyncTestError.unavailable

    let snapshot = try await services.secondDevice.loadSnapshotForProviderAccess(
      session: secondDeviceSession
    )

    XCTAssertTrue(snapshot.connections.isEmpty)
    XCTAssertEqual(snapshot.removedConnectionIds, [Self.connection.id])
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

  func testCancelledSnapshotLoadPreservesCiphertextCache() async throws {
    let cacheStore = InMemoryMailboxConnectionSyncCacheStore()
    let cachedPayload = EncryptedProductSyncPayload(
      encryptedPayload: ProductSyncEncryptedPayload(
        algorithm: ProductSyncEncryptedPayload.algorithmName,
        ciphertextBase64: "unused",
        keyVersion: 1,
        nonceBase64: "unused",
        schemaVersion: 1,
        tagBase64: "unused"
      ),
      payloadIdentifier: MailboxConnectionSyncPayload.primaryIdentifier,
      updatedAt: 42
    )
    try cacheStore.replaceIfNotOlder(
      cachedPayload,
      productAccountId: firstDeviceSession.productAccountId
    )
    let transport = RecordingMailboxConnectionSyncTransport()
    transport.loadError = CancellationError()
    let service = MailboxConnectionSyncService(
      cacheStore: cacheStore,
      keyMaterialStore: InMemoryProductSyncKeyMaterialStore(),
      transport: transport
    )

    do {
      _ = try await service.loadSnapshot(session: firstDeviceSession)
      XCTFail("Expected cancellation")
    } catch is CancellationError {}

    let preservedPayload = try cacheStore.load(
      productAccountId: firstDeviceSession.productAccountId
    )
    XCTAssertEqual(preservedPayload, cachedPayload)
  }

  func testProviderAccessSerializesProductSyncLoadsPerAccount() async throws {
    let transport = ProviderAccessConcurrencyTransport()
    let firstService = MailboxConnectionSyncService(
      cacheStore: InMemoryMailboxConnectionSyncCacheStore(),
      transport: transport
    )
    let secondService = MailboxConnectionSyncService(
      cacheStore: InMemoryMailboxConnectionSyncCacheStore(),
      transport: transport
    )

    async let first = firstService.loadSnapshotForProviderAccess(session: firstDeviceSession)
    async let second = secondService.loadSnapshotForProviderAccess(session: firstDeviceSession)
    _ = try await (first, second)

    let maximumConcurrentLoadCount = await transport.maximumConcurrentLoadCount
    XCTAssertEqual(maximumConcurrentLoadCount, 1)
  }

  func testCancelledProviderAccessWaiterDoesNotEnterTransport() async throws {
    let transport = ProviderAccessConcurrencyTransport(blocksLoads: true)
    let firstService = MailboxConnectionSyncService(
      cacheStore: InMemoryMailboxConnectionSyncCacheStore(),
      transport: transport
    )
    let secondService = MailboxConnectionSyncService(
      cacheStore: InMemoryMailboxConnectionSyncCacheStore(),
      transport: transport
    )
    let first = Task {
      try await firstService.loadSnapshotForProviderAccess(session: firstDeviceSession)
    }
    while await transport.loadCallCount == 0 {
      await Task.yield()
    }
    let cancelled = Task {
      try await secondService.loadSnapshotForProviderAccess(session: firstDeviceSession)
    }
    while await MailboxConnectionSyncService.providerAccessWaiterCountForTesting(
      productAccountId: firstDeviceSession.productAccountId
    ) == 0 {
      await Task.yield()
    }
    cancelled.cancel()

    do {
      _ = try await cancelled.value
      XCTFail("Expected the queued provider-access load to be cancelled")
    } catch is CancellationError {
      // Expected.
    }
    let loadCallCount = await transport.loadCallCount
    XCTAssertEqual(loadCallCount, 1)
    await transport.releaseBlockedLoads()
    _ = try await first.value
  }

  private func observedRemoval(
    using service: MailboxConnectionSyncService
  ) async throws -> MailboxConnectionRemovalObservation {
    do {
      _ = try await service.recreateDefinition(
        Self.connection.definition,
        after: nil,
        session: secondDeviceSession
      )
      throw MailboxConnectionSyncTestError.expectedRemoval
    } catch let error as MailboxConnectionSyncError {
      guard case .connectionRemoved(let observation) = error else { throw error }
      return observation
    }
  }

  private func recreateConnection(
    using service: MailboxConnectionSyncService,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    let observation: MailboxConnectionRemovalObservation
    do {
      _ = try await service.recreateDefinition(
        Self.connection.definition,
        after: nil,
        session: session
      )
      throw MailboxConnectionSyncTestError.expectedRemoval
    } catch let error as MailboxConnectionSyncError {
      guard case .connectionRemoved(let currentObservation) = error else { throw error }
      observation = currentObservation
    }
    return try await service.recreateDefinition(
      Self.connection.definition,
      after: observation,
      session: session
    )
  }

  private func makeServices(
    clock: @escaping () -> Int64 = {
      Int64(Date().timeIntervalSince1970 * 1_000)
    }
  ) throws -> Services {
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
        clock: clock,
        keyMaterialStore: firstStore,
        transport: transport
      ),
      keyMaterial: keyMaterial,
      secondDevice: MailboxConnectionSyncService(
        cacheStore: InMemoryMailboxConnectionSyncCacheStore(),
        clock: clock,
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
  var afterGenerationFloorWrite: (() async throws -> Void)?
  var beforeGenerationFloorWrite: ((Int) async throws -> Void)?
  var generationWriteError: Error?
  var generationWriteFailureCountdown: Int?
  var loadError: Error?
  var payloadLoadErrors: [String: Error] = [:]
  var primaryWriteError: Error?
  var payload: EncryptedProductSyncPayload? {
    payloads["mailbox-connections-primary"]
  }
  private var payloads: [String: EncryptedProductSyncPayload] = [:]
  private var generationWriteCount = 0
  private var updatedAt: Int64 = 1_781_200_000_000

  func listEncryptedProductSyncPayloads(
    identityToken _: String,
    payloadIdentifierPrefix _: String?,
    trustedDeviceId _: String
  ) async throws -> [EncryptedProductSyncPayload] {
    additionalPayloads
      + payloads.values.sorted { $0.payloadIdentifier < $1.payloadIdentifier }
  }

  func getEncryptedProductSyncPayload(
    identityToken _: String,
    payloadIdentifier: String,
    trustedDeviceId _: String
  ) async throws -> EncryptedProductSyncPayload? {
    if let loadError { throw loadError }
    if let error = payloadLoadErrors[payloadIdentifier] { throw error }
    return payloads[payloadIdentifier]
  }

  func getEncryptedProductSyncPayloads(
    identityToken _: String,
    payloadIdentifiers: [String],
    trustedDeviceId _: String
  ) async throws -> [EncryptedProductSyncPayload] {
    if let loadError { throw loadError }
    for identifier in payloadIdentifiers {
      if let error = payloadLoadErrors[identifier] { throw error }
    }
    return payloadIdentifiers.compactMap { payloads[$0] }
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
    if payloadIdentifier == "mailbox-connections-primary", let primaryWriteError {
      throw primaryWriteError
    }
    if payloadIdentifier == "mailbox-authorization-generations-v1" {
      generationWriteCount += 1
      if let remaining = generationWriteFailureCountdown {
        if remaining == 1, let generationWriteError {
          generationWriteFailureCountdown = nil
          throw generationWriteError
        }
        generationWriteFailureCountdown = remaining - 1
      }
      try await beforeGenerationFloorWrite?(generationWriteCount)
    }
    let existing = payloads[payloadIdentifier]
    guard existing?.updatedAt == expectedUpdatedAt else {
      return try XCTUnwrap(existing)
    }
    let payload = write(payloadIdentifier: payloadIdentifier, encryptedPayload: encryptedPayload)
    if payloadIdentifier == "mailbox-authorization-generations-v1",
      let afterGenerationFloorWrite
    {
      self.afterGenerationFloorWrite = nil
      try await afterGenerationFloorWrite()
    }
    return payload
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
  case expectedRemoval
  case unavailable
}

private actor ProviderAccessConcurrencyTransport: ProductSyncPayloadTransport {
  private(set) var loadCallCount = 0
  private(set) var maximumConcurrentLoadCount = 0
  private let blocksLoads: Bool
  private var blockedLoadContinuations: [CheckedContinuation<Void, Never>] = []
  private var concurrentLoadCount = 0

  init(blocksLoads: Bool = false) {
    self.blocksLoads = blocksLoads
  }

  func releaseBlockedLoads() {
    let continuations = blockedLoadContinuations
    blockedLoadContinuations.removeAll()
    for continuation in continuations {
      continuation.resume()
    }
  }

  func listEncryptedProductSyncPayloads(
    identityToken _: String,
    payloadIdentifierPrefix _: String?,
    trustedDeviceId _: String
  ) async throws -> [EncryptedProductSyncPayload] {
    []
  }

  func getEncryptedProductSyncPayload(
    identityToken _: String,
    payloadIdentifier _: String,
    trustedDeviceId _: String
  ) async throws -> EncryptedProductSyncPayload? {
    nil
  }

  func getEncryptedProductSyncPayloads(
    identityToken _: String,
    payloadIdentifiers _: [String],
    trustedDeviceId _: String
  ) async throws -> [EncryptedProductSyncPayload] {
    loadCallCount += 1
    concurrentLoadCount += 1
    maximumConcurrentLoadCount = max(maximumConcurrentLoadCount, concurrentLoadCount)
    if blocksLoads {
      await withCheckedContinuation { continuation in
        blockedLoadContinuations.append(continuation)
      }
    } else {
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    concurrentLoadCount -= 1
    return []
  }

  func putEncryptedProductSyncPayload(
    identityToken _: String,
    payloadIdentifier _: String,
    encryptedPayload _: ProductSyncEncryptedPayload,
    trustedDeviceId _: String
  ) async throws -> EncryptedProductSyncPayload {
    throw MailboxConnectionSyncTestError.unavailable
  }

  func putEncryptedProductSyncPayloadIfAbsent(
    identityToken _: String,
    payloadIdentifier _: String,
    encryptedPayload _: ProductSyncEncryptedPayload,
    trustedDeviceId _: String
  ) async throws -> EncryptedProductSyncPayload {
    throw MailboxConnectionSyncTestError.unavailable
  }

  func putEncryptedProductSyncPayloadIfUnchanged(
    identityToken _: String,
    payloadIdentifier _: String,
    encryptedPayload _: ProductSyncEncryptedPayload,
    trustedDeviceId _: String,
    expectedUpdatedAt _: Int64?
  ) async throws -> EncryptedProductSyncPayload {
    throw MailboxConnectionSyncTestError.unavailable
  }
}
