import Foundation
import Testing

@testable import unwired_mail

// swiftlint:disable file_length type_body_length
@Suite(.serialized)
final class MailboxConnectionSyncServiceTests {
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

  @Test
  func testConnectionCreatedOnOneDeviceAppearsOnAnotherWithoutAuthorization() async throws {
    let services = try makeServices()

    _ = try await services.firstDevice.saveConnection(
      Self.connection,
      session: firstDeviceSession
    )
    let secondDeviceSnapshot = try await services.secondDevice.loadSnapshot(
      session: secondDeviceSession
    )

    #expect(secondDeviceSnapshot.connections == [Self.connection.definition])
    #expect(secondDeviceSnapshot.defaultSendingConnectionId == nil)
  }

  @Test
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

    #expect(
      secondDeviceSnapshot.connections.first?.genericMailDefinition == Self.genericMailDefinition)
    let encryptedPayload = try requireValue(services.transport.payload?.encryptedPayload)
    #expect(!(encryptedPayload.ciphertextBase64.contains("imap.example.com")))
    #expect(!(encryptedPayload.ciphertextBase64.contains("reader@example.com")))
  }

  @Test
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

    #expect(Self.genericMailDefinition.connectionId != otherEndpointDefinition.connectionId)
    #expect(snapshot.connections.count == 2)
  }

  @Test
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

    #expect(secondDeviceSnapshot.defaultSendingConnectionId == Self.connection.id)
    #expect(secondDeviceSnapshot.defaultSendingConnectionId != Self.otherConnection.id)
  }

  @Test
  func testRemovalTombstonePreventsAnOfflineDeviceFromResurrectingAConnection() async throws {
    let services = try makeServices()
    _ = try await services.firstDevice.saveConnection(
      Self.connection,
      session: firstDeviceSession
    )
    let offlineSnapshot = try await services.secondDevice.loadSnapshot(
      session: secondDeviceSession
    )
    let offlineConnection = try requireValue(offlineSnapshot.connections.first)

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

    #expect(convergedSnapshot.connections.isEmpty)
    #expect(convergedSnapshot.removedConnectionIds == [Self.connection.id])
  }

  @Test
  func testReaddedConnectionAdvancesGenerationBeforeOfflineDeviceReconciles() async throws {
    let services = try makeServices()
    let originalSnapshot = try await services.firstDevice.saveConnection(
      Self.connection,
      session: firstDeviceSession
    )
    let offlineDefinition = try requireValue(originalSnapshot.connections.first)

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

    #expect(offlineDefinition.authorizationGeneration == 0)
    #expect(recreatedSnapshot.connections.first?.authorizationGeneration == 1)
    #expect(convergedSnapshot.connections.first?.authorizationGeneration == 1)
    #expect(convergedSnapshot.removedConnectionIds.isEmpty)
    #expect(convergedSnapshot.authorizationCleanupConnectionIds == [Self.connection.id])
  }

  @Test
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

    #expect(recreatedSnapshot.connections.first?.authorizationGeneration == 1)
  }

  @Test
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
    _ = try await services.transport.seedEncryptedProductSyncPayload(
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

    #expect(snapshot.connections.first?.authorizationGeneration == 1)
    #expect(offlineSnapshot.connections.first?.authorizationGeneration == 1)
    #expect(snapshot.removedConnectionIds.isEmpty)
  }

  @Test
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
    _ = try await services.transport.seedEncryptedProductSyncPayload(
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
    _ = try await services.transport.seedEncryptedProductSyncPayload(
      identityToken: secondDeviceSession.identityToken,
      payloadIdentifier: "mailbox-connections-primary",
      encryptedPayload: encryptedDefinitionPayload,
      trustedDeviceId: secondDeviceSession.trustedDeviceId
    )

    let snapshot = try await services.firstDevice.loadSnapshot(session: firstDeviceSession)

    #expect(recreated.connections.first?.authorizationGeneration == 1)
    #expect(snapshot.connections.first?.authorizationGeneration == 1)
  }

  @Test
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
    _ = try await services.transport.seedEncryptedProductSyncPayload(
      identityToken: secondDeviceSession.identityToken,
      payloadIdentifier: "mailbox-connections-primary",
      encryptedPayload: encryptedPayload,
      trustedDeviceId: secondDeviceSession.trustedDeviceId
    )

    let snapshot = try await services.firstDevice.loadSnapshot(session: firstDeviceSession)

    #expect(snapshot.connections.first?.authorizationGeneration == 2)
    #expect(snapshot.authorizationCleanupConnectionIds == [Self.connection.id])
  }

  @Test
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

    #expect(snapshot.connections.first?.authorizationGeneration == 1)
  }

  @Test
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
    let removedPayload = try requireValue(services.transport.payload)
    let plaintext = try services.keyMaterial.decryptPayload(
      removedPayload.encryptedPayload,
      associatedData: Data("mailbox-connections-primary".utf8)
    )
    var payload = try requireValue(JSONSerialization.jsonObject(with: plaintext) as? [String: Any])
    payload["connections"] = [
      try requireValue(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.connection.definition))
          as? [String: Any])
    ]
    let encryptedPayload = try services.keyMaterial.encryptPayload(
      JSONSerialization.data(withJSONObject: payload),
      associatedData: Data("mailbox-connections-primary".utf8)
    )
    _ = try await services.transport.seedEncryptedProductSyncPayload(
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

    #expect(retainedSnapshot.connections.count == 1)
    #expect(retainedSnapshot.removedConnectionIds.isEmpty)
    #expect(retainedSnapshot.authorizationCleanupConnectionIds == [Self.connection.id])
    #expect(reauthorizedSnapshot.removedConnectionIds.isEmpty)
    #expect(reauthorizedSnapshot.authorizationCleanupConnectionIds == [Self.connection.id])
  }

  @Test
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
    let remotePayload = try requireValue(services.transport.payload)
    let plaintext = try services.keyMaterial.decryptPayload(
      remotePayload.encryptedPayload,
      associatedData: Data("mailbox-connections-primary".utf8)
    )
    let payload = try requireValue(JSONSerialization.jsonObject(with: plaintext) as? [String: Any])
    let removals = try requireValue(payload["removals"] as? [[String: Any]])

    #expect(removals.count == 1)
    #expect(reauthorized.removedConnectionIds.isEmpty)
    #expect(reauthorized.authorizationCleanupConnectionIds == [Self.connection.id])
  }

  @Test
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
      Issue.record("Expected primary tombstone publication to fail")
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
    _ = try await services.transport.seedEncryptedProductSyncPayload(
      identityToken: secondDeviceSession.identityToken,
      payloadIdentifier: "mailbox-connections-primary",
      encryptedPayload: encryptedLegacyPayload,
      trustedDeviceId: secondDeviceSession.trustedDeviceId
    )

    let snapshot = try await services.secondDevice.loadSnapshot(session: secondDeviceSession)

    #expect(snapshot.connections.first?.authorizationGeneration == 0)
    #expect(snapshot.removedConnectionIds.isEmpty)
  }

  @Test
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
      Issue.record("Expected second tombstone publication to fail")
    } catch MailboxConnectionSyncTestError.unavailable {
      // Expected.
    }
    services.transport.primaryWriteError = nil
    var legacyDefinition = try requireValue(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.connection.definition))
        as? [String: Any])
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
    _ = try await services.transport.seedEncryptedProductSyncPayload(
      identityToken: firstDeviceSession.identityToken,
      payloadIdentifier: "mailbox-connections-primary",
      encryptedPayload: encryptedLegacyPayload,
      trustedDeviceId: firstDeviceSession.trustedDeviceId
    )

    let snapshot = try await services.secondDevice.loadSnapshot(session: secondDeviceSession)

    #expect(snapshot.connections.first?.authorizationGeneration == 1)
    #expect(snapshot.removedConnectionIds.isEmpty)
  }

  @Test
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
      Issue.record("Expected generation-floor finalization to fail")
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
    _ = try await services.transport.seedEncryptedProductSyncPayload(
      identityToken: secondDeviceSession.identityToken,
      payloadIdentifier: "mailbox-connections-primary",
      encryptedPayload: encryptedLegacyPayload,
      trustedDeviceId: secondDeviceSession.trustedDeviceId
    )

    let snapshot = try await services.secondDevice.loadSnapshot(session: secondDeviceSession)

    #expect(snapshot.connections.first?.authorizationGeneration == 1)
  }

  @Test
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
      Issue.record("Expected the newer removal publication to fail")
    } catch MailboxConnectionSyncTestError.unavailable {
      // Expected.
    }
    services.transport.primaryWriteError = nil
    await finalizerGate.release()
    _ = try await firstRemoval.value

    let snapshot = try await services.firstDevice.loadSnapshot(session: firstDeviceSession)

    #expect(snapshot.connections.first?.authorizationGeneration == 1)
  }

  @Test
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
    let removedPayload = try requireValue(services.transport.payload)
    let plaintext = try services.keyMaterial.decryptPayload(
      removedPayload.encryptedPayload,
      associatedData: Data("mailbox-connections-primary".utf8)
    )
    var payload = try requireValue(JSONSerialization.jsonObject(with: plaintext) as? [String: Any])
    payload["connections"] = [
      try requireValue(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.connection.definition))
          as? [String: Any])
    ]
    payload["defaultSendingConnectionProvider"] = Self.connection.id.providerId.rawValue
    payload["defaultSendingProviderAccountIdentifier"] =
      Self.connection.id.providerMailboxIdentity.value
    let encryptedPayload = try services.keyMaterial.encryptPayload(
      JSONSerialization.data(withJSONObject: payload),
      associatedData: Data("mailbox-connections-primary".utf8)
    )
    _ = try await services.transport.seedEncryptedProductSyncPayload(
      identityToken: firstDeviceSession.identityToken,
      payloadIdentifier: "mailbox-connections-primary",
      encryptedPayload: encryptedPayload,
      trustedDeviceId: firstDeviceSession.trustedDeviceId
    )

    let snapshot = try await services.firstDevice.removeConnection(
      Self.connection.id,
      session: firstDeviceSession
    )

    #expect(snapshot.connections.isEmpty)
    #expect(snapshot.removedConnectionIds == [Self.connection.id])
    #expect(snapshot.defaultSendingConnectionId == nil)
  }

  @Test
  func testSavingAStaleDefinitionDoesNotClearItsRemovalTombstone() async throws {
    let services = try makeServices()
    _ = try await services.firstDevice.saveConnection(
      Self.connection,
      session: firstDeviceSession
    )
    let staleSnapshot = try await services.secondDevice.loadSnapshot(session: secondDeviceSession)
    let staleDefinition = try requireValue(staleSnapshot.connections.first)

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
      Issue.record("Expected the stale definition save to report the remote removal")
    } catch let error as MailboxConnectionSyncError {
      if case .connectionRemoved(let observation) = error {
        observedRemoval = observation
      } else {
        Issue.record("Unexpected Mailbox Connection sync error: \(error)")
      }
    }
    let snapshot = try await services.firstDevice.loadSnapshot(session: firstDeviceSession)

    #expect(snapshot.connections.isEmpty)
    #expect(snapshot.removedConnectionIds == [Self.connection.id])
    #expect(observedRemoval?.connectionId == Self.connection.id)
  }

  @Test
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

    #expect(snapshot.connections == [Self.connection.definition.withAuthorizationGeneration(1)])
    #expect(snapshot.removedConnectionIds.isEmpty)
    #expect(snapshot.authorizationCleanupConnectionIds == [Self.connection.id])
  }

  @Test
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
      Issue.record("Expected the stale observation to reject the repeated tombstone")
    } catch let error as MailboxConnectionSyncError {
      guard case .connectionRemoved(let currentObservation) = error else {
        Issue.record("Unexpected Mailbox Connection sync error: \(error)")
        return
      }
      #expect(currentObservation.removedAt == firstObservation.removedAt)
      #expect(currentObservation.tombstoneIdentifier != firstObservation.tombstoneIdentifier)
    }
  }

  @Test
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
      Issue.record("Expected the stale recreation confirmation to be rejected")
    } catch let error as MailboxConnectionSyncError {
      #expect(error == .concurrentModification)
    }
  }

  @Test
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

    #expect(snapshot.connections == [Self.otherConnection.definition])
    #expect(snapshot.removedConnectionIds == [Self.connection.id])
  }

  @Test
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
      Issue.record("Expected the stale definition save to report the removal")
    } catch let error as MailboxConnectionSyncError {
      guard case .connectionRemoved = error else {
        Issue.record("Unexpected Mailbox Connection sync error: \(error)")
        return
      }
    }
    services.transport.loadError = MailboxConnectionSyncTestError.unavailable

    let snapshot = try await services.secondDevice.loadSnapshotForProviderAccess(
      session: secondDeviceSession
    )

    #expect(snapshot.connections.isEmpty)
    #expect(snapshot.removedConnectionIds == [Self.connection.id])
  }

  @Test
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

    #expect(snapshot.defaultSendingConnectionId == nil)
    #expect(snapshot.connections == [Self.otherConnection.definition])
  }

  @Test
  func testMailboxDefinitionIsOpaqueToProductSyncTransport() async throws {
    let services = try makeServices()

    _ = try await services.firstDevice.saveConnection(
      Self.connection,
      session: firstDeviceSession
    )

    let writtenPayload = try requireValue(services.transport.payload)
    #expect(writtenPayload.payloadIdentifier == "mailbox-connections-primary")
    #expect(!(writtenPayload.encryptedPayload.ciphertextBase64.contains("user@example.com")))
    #expect(!(writtenPayload.encryptedPayload.ciphertextBase64.contains("gmail-user-001")))
  }

  @Test
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

    #expect(snapshot.connections == [Self.connection.definition])
  }

  @Test
  func testTransportFailureDuringSnapshotLoadPreservesProviderAccessCache() async throws {
    let services = try makeServices()
    _ = try await services.firstDevice.saveConnection(
      Self.connection,
      session: firstDeviceSession
    )
    _ = try await services.secondDevice.loadSnapshot(session: secondDeviceSession)
    services.transport.loadError = MailboxConnectionSyncTestError.unavailable

    do {
      _ = try await services.secondDevice.loadSnapshot(session: secondDeviceSession)
      Issue.record("Expected the transport failure")
    } catch is MailboxConnectionSyncTestError {}

    let snapshot = try await services.secondDevice.loadSnapshotForProviderAccess(
      session: secondDeviceSession
    )
    #expect(snapshot.connections == [Self.connection.definition])
  }

  @Test
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
      recordBoundary: ProductSyncRecordBoundary(
        keyMaterialStore: InMemoryProductSyncKeyMaterialStore(), transport: transport)
    )

    do {
      _ = try await service.loadSnapshot(session: firstDeviceSession)
      Issue.record("Expected cancellation")
    } catch is CancellationError {}

    let preservedPayload = try cacheStore.load(
      productAccountId: firstDeviceSession.productAccountId
    )
    #expect(preservedPayload == cachedPayload)
  }

  @Test
  func testProviderAccessSerializesProductSyncLoadsPerAccount() async throws {
    let transport = ProviderAccessConcurrencyTransport()
    let firstService = MailboxConnectionSyncService(
      cacheStore: InMemoryMailboxConnectionSyncCacheStore(),
      recordBoundary: ProductSyncRecordBoundary(transport: transport)
    )
    let secondService = MailboxConnectionSyncService(
      cacheStore: InMemoryMailboxConnectionSyncCacheStore(),
      recordBoundary: ProductSyncRecordBoundary(transport: transport)
    )

    async let first = firstService.loadSnapshotForProviderAccess(session: firstDeviceSession)
    async let second = secondService.loadSnapshotForProviderAccess(session: firstDeviceSession)
    _ = try await (first, second)

    let maximumConcurrentLoadCount = await transport.maximumConcurrentLoadCount
    #expect(maximumConcurrentLoadCount == 1)
  }

  @Test
  func testCancelledProviderAccessWaiterDoesNotEnterTransport() async throws {
    let transport = ProviderAccessConcurrencyTransport(blocksLoads: true)
    let firstService = MailboxConnectionSyncService(
      cacheStore: InMemoryMailboxConnectionSyncCacheStore(),
      recordBoundary: ProductSyncRecordBoundary(transport: transport)
    )
    let secondService = MailboxConnectionSyncService(
      cacheStore: InMemoryMailboxConnectionSyncCacheStore(),
      recordBoundary: ProductSyncRecordBoundary(transport: transport)
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
      Issue.record("Expected the queued provider-access load to be cancelled")
    } catch is CancellationError {
      // Expected.
    }
    let loadCallCount = await transport.loadCallCount
    #expect(loadCallCount == 1)
    await transport.releaseBlockedLoads()
    _ = try await first.value
  }

  @Test
  func testLegacyProductAccountMigratesToOneEncryptedDefaultProfileWithoutCopyingState()
    async throws
  {
    let services = try makeServices()
    _ = try await services.firstDevice.saveConnection(Self.connection, session: firstDeviceSession)
    _ = try await services.firstDevice.saveConnection(
      Self.otherConnection,
      session: firstDeviceSession
    )
    let mailboxPayloadBeforeMigration = services.transport.payload

    let snapshot = try await services.firstDevice.loadProfileSnapshot(
      session: firstDeviceSession
    )
    let profile = try requireValue(snapshot.profiles.first)

    #expect(snapshot.profiles.count == 1)
    #expect(profile.id == .defaultProfile(productAccountId: firstDeviceSession.productAccountId))
    #expect(profile.name == "Default Profile")
    #expect(profile.recordScope == .legacyProductAccount)
    #expect(snapshot.assignments.count == 2)
    #expect(Set(snapshot.assignments.values) == [profile.id])
    #expect(services.transport.payload == mailboxPayloadBeforeMigration)

    let encryptedProfile = try requireValue(services.transport.profilePayload)
    #expect(!encryptedProfile.encryptedPayload.ciphertextBase64.contains("Default Profile"))
    #expect(
      !encryptedProfile.encryptedPayload.ciphertextBase64.contains(
        firstDeviceSession.productAccountId
      )
    )
    #expect(
      profile.recordScope.productSyncIdentifier("custom-categories-primary")
        == "custom-categories-primary"
    )
  }

  @Test
  func testDefaultProfileMigrationIsIdempotentAndClaimsConnectionsAddedByOlderClients()
    async throws
  {
    let services = try makeServices()
    _ = try await services.firstDevice.saveConnection(Self.connection, session: firstDeviceSession)
    let initial = try await services.firstDevice.loadProfileSnapshot(session: firstDeviceSession)
    let initialRevision = services.transport.profilePayload?.updatedAt

    _ = try await services.secondDevice.saveConnection(
      Self.otherConnection,
      session: secondDeviceSession
    )
    let migrated = try await services.firstDevice.loadProfileSnapshot(session: firstDeviceSession)
    let migratedRevision = services.transport.profilePayload?.updatedAt
    let repeated = try await services.secondDevice.loadProfileSnapshot(session: secondDeviceSession)

    #expect(initial.assignments.count == 1)
    #expect(migrated.assignments.count == 2)
    #expect(repeated == migrated)
    #expect(initialRevision != migratedRevision)
    #expect(services.transport.profilePayload?.updatedAt == migratedRevision)
  }

  @Test
  func testWorkspaceSelectionKeepsWindowsAndConnectionsInsideOneProfile() throws {
    let defaultProfileId = MailProfileId(rawValue: "profile-personal")
    let workProfileId = MailProfileId(rawValue: "profile-work")
    let snapshot = MailProfileSyncSnapshot(
      assignments: [
        Self.connection.id: defaultProfileId,
        Self.otherConnection.id: workProfileId,
      ],
      conflicts: [],
      defaultProfileId: defaultProfileId,
      profiles: [
        MailProfileDefinition(
          id: defaultProfileId,
          appearance: .default,
          name: "Personal",
          recordScope: .legacyProductAccount,
          quietState: .inactive
        ),
        MailProfileDefinition(
          id: workProfileId,
          appearance: MailProfileAppearance(colorName: "orange", symbolName: "briefcase"),
          name: "Work",
          recordScope: .profile(workProfileId),
          quietState: .inactive
        ),
      ],
      updatedAt: 1
    )

    let personalWindow = MailProfileWorkspaceSelection(
      snapshot: snapshot,
      restoredProfileId: defaultProfileId
    )
    let workWindow = MailProfileWorkspaceSelection(
      snapshot: snapshot,
      restoredProfileId: workProfileId
    )

    #expect(personalWindow.activeProfile?.name == "Personal")
    #expect(
      personalWindow.connections(from: [Self.connection, Self.otherConnection]) == [
        Self.connection
      ])
    #expect(workWindow.activeProfile?.name == "Work")
    #expect(
      workWindow.connections(from: [Self.connection, Self.otherConnection]) == [
        Self.otherConnection
      ])
  }

  @Test
  func testTargetedProfileOverridesRestorationAndStartupSelection() {
    let defaultProfileId = MailProfileId(rawValue: "profile-personal")
    let workProfileId = MailProfileId(rawValue: "profile-work")
    let snapshot = workspaceSnapshot(
      defaultProfileId: defaultProfileId,
      workProfileId: workProfileId
    )

    let targeted = MailProfileWorkspaceSelection(
      snapshot: snapshot,
      targetedProfileId: workProfileId,
      restoredProfileId: defaultProfileId,
      startupProfileId: defaultProfileId
    )
    let restored = MailProfileWorkspaceSelection(
      snapshot: snapshot,
      restoredProfileId: workProfileId,
      startupProfileId: defaultProfileId
    )
    let startup = MailProfileWorkspaceSelection(
      snapshot: snapshot,
      restoredProfileId: MailProfileId(rawValue: "missing"),
      startupProfileId: workProfileId
    )

    #expect(targeted.activeProfileId == workProfileId)
    #expect(restored.activeProfileId == workProfileId)
    #expect(startup.activeProfileId == workProfileId)
  }

  @Test
  func testProfileSwitchDoesNotCommitWhenDraftParkingFails() throws {
    let defaultProfileId = MailProfileId(rawValue: "profile-personal")
    let workProfileId = MailProfileId(rawValue: "profile-work")
    let selection = MailProfileWorkspaceSelection(
      snapshot: workspaceSnapshot(
        defaultProfileId: defaultProfileId,
        workProfileId: workProfileId
      )
    )

    #expect(throws: MailboxConnectionSyncTestError.unavailable) {
      _ = try selection.activating(workProfileId) {
        throw MailboxConnectionSyncTestError.unavailable
      }
    }
    #expect(selection.activeProfileId == defaultProfileId)
  }

  @Test
  func testProfileDeepLinksRoundTripWithoutExposingProfileNames() throws {
    let profileId = MailProfileId(rawValue: "opaque-profile-id")
    let deepLink = MailProfileDeepLink(profileId: profileId)
    let parsed = try requireValue(MailProfileDeepLink(url: deepLink.url))

    #expect(parsed.profileId == profileId)
    #expect(deepLink.url.absoluteString.contains("opaque-profile-id"))
    #expect(!(deepLink.url.absoluteString.contains("Work")))
    #expect(MailProfileDeepLink(url: URL(string: "https://example.com")!) == nil)
  }

  @Test
  func testStartupProfileSelectionIsDeviceLocalAndProductAccountScoped() throws {
    let suiteName = "MailProfileStartupSelectionTests.\(UUID().uuidString)"
    let defaults = try requireValue(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = UserDefaultsMailProfileStartupStore(defaults: defaults)
    let profileId = MailProfileId(rawValue: "profile-work")

    store.save(profileId, productAccountId: "account-a")

    #expect(store.load(productAccountId: "account-a") == profileId)
    #expect(store.load(productAccountId: "account-b") == nil)
  }

  @Test @MainActor
  func testProfileDeepLinkRoutersAreIsolatedPerScene() {
    let firstScene = MailProfileDeepLinkRouter()
    let secondScene = MailProfileDeepLinkRouter()
    let profileId = MailProfileId(rawValue: "profile-work")

    firstScene.route(profileId: profileId)

    #expect(firstScene.consumeTargetedProfileId() == profileId)
    #expect(secondScene.consumeTargetedProfileId() == nil)
  }

  @Test @MainActor
  func testOutboxPresentationFiltersAttemptsToProfileConnections() {
    func attempt(connectionId: MailboxConnectionId) -> OutgoingDeliveryAttempt {
      OutgoingDeliveryAttempt(
        attemptCount: 0,
        connectionId: connectionId,
        createdAtMilliseconds: 1,
        firstAttemptAtMilliseconds: nil,
        id: UUID(),
        idempotencyKey: UUID().uuidString,
        lastErrorDescription: nil,
        message: OutgoingMessage(
          body: "Private body",
          recipient: "reader@example.com",
          subject: "Queued message"
        ),
        nextRetryAtMilliseconds: nil,
        productAccountId: ProductAccountId(firstDeviceSession.productAccountId),
        reconciliationAttemptCount: 0,
        state: .pending
      )
    }
    let personalConnectionId = Self.connection.id
    let workConnectionId = Self.otherConnection.id
    let personalAttempt = attempt(connectionId: personalConnectionId)
    let workAttempt = attempt(connectionId: workConnectionId)

    let presented = profileScopedOutboxItems(
      [personalAttempt, workAttempt],
      connectionIds: [personalConnectionId]
    )

    #expect(presented.map(\.id) == [personalAttempt.id])
    #expect(presented.map(GmailMailActionViewModel.outboxState) == [.pending])
  }

  @Test @MainActor
  func testProfilePresentationBoundariesKeepIdleGlobalAndCacheClearingScoped() {
    let accountConnections = [Self.connection, Self.otherConnection]

    #expect(
      standardsMailIdleConnection(
        rawConnectionId: Self.otherConnection.id.rawValue,
        accountConnections: accountConnections
      )?.id == Self.otherConnection.id
    )
    #expect(
      profileScopedCacheClearConnections(
        selectedConnection: nil,
        profileConnections: [Self.connection]
      ).map(\.id) == [Self.connection.id]
    )
    #expect(
      profileScopedCacheClearConnections(
        selectedConnection: Self.connection,
        profileConnections: accountConnections
      ).map(\.id) == [Self.connection.id]
    )
  }

  @Test @MainActor
  func testNotificationConnectionSelectionWaitsForProfileActivation() async {
    let activationGate = ControlledProfileActivationGate()
    var didInspectProfileConnections = false
    let navigation = Task {
      await profileConnectionAfterActivation(
        Self.connection.id,
        activate: {
          await activationGate.wait()
          return true
        },
        connections: {
          didInspectProfileConnections = true
          return [Self.connection]
        }
      )
    }
    await activationGate.waitUntilBlocked()

    #expect(!didInspectProfileConnections)
    await activationGate.release()
    let selected = await navigation.value
    #expect(didInspectProfileConnections)
    #expect(selected?.id == Self.connection.id)
  }

  @Test @MainActor
  func testOlderProfileLoadsCannotReplaceANewerTargetOrManualActivation() async throws {
    let defaultProfileId = MailProfileId(rawValue: "profile-personal")
    let workProfileId = MailProfileId(rawValue: "profile-work")
    let snapshot = workspaceSnapshot(
      defaultProfileId: defaultProfileId,
      workProfileId: workProfileId
    )
    let loader = ControlledProfileSnapshotLoader()
    let viewModel = MailProfileWorkspaceViewModel(
      session: firstDeviceSession,
      snapshotLoader: loader,
      startupStore: InMemoryMailProfileStartupStore()
    )
    let firstLoad = Task {
      await viewModel.load(restoredProfileId: defaultProfileId)
    }
    await loader.waitForRequestCount(1)
    let targetedLoad = Task {
      await viewModel.load(
        restoredProfileId: defaultProfileId,
        targetedProfileId: workProfileId
      )
    }
    await loader.waitForRequestCount(2)
    await loader.resumeRequest(1, with: snapshot)
    await targetedLoad.value
    await loader.resumeRequest(0, with: snapshot)
    await firstLoad.value
    #expect(viewModel.activeProfileId == workProfileId)

    let staleReload = Task {
      await viewModel.load(restoredProfileId: defaultProfileId)
    }
    await loader.waitForRequestCount(3)
    try viewModel.activate(defaultProfileId)
    await loader.resumeRequest(2, with: snapshot)
    await staleReload.value
    #expect(viewModel.activeProfileId == defaultProfileId)
  }

  @Test
  func testProfileMigrationRepairsAMissingDefaultProfileDeterministically() async throws {
    let services = try makeServices()
    let customProfileId = MailProfileId(rawValue: "custom-profile")
    let customProfile = MailProfileDefinition(
      id: customProfileId,
      appearance: .default,
      name: "Custom",
      recordScope: .profile(customProfileId),
      quietState: .inactive
    )
    try await seedProfilePayload(
      MailProfileSyncPayload(
        assignments: [],
        conflicts: [],
        defaultProfileId: MailProfileId(rawValue: "missing-profile"),
        profiles: [customProfile],
        schemaVersion: 1
      ),
      services: services
    )

    let repaired = try await services.firstDevice.loadProfileSnapshot(session: firstDeviceSession)
    let repairedRevision = services.transport.profilePayload?.updatedAt
    let repeated = try await services.secondDevice.loadProfileSnapshot(session: secondDeviceSession)

    #expect(
      repaired.defaultProfileId
        == .defaultProfile(productAccountId: firstDeviceSession.productAccountId))
    #expect(Set(repaired.profiles.map(\.id)) == [customProfileId, repaired.defaultProfileId])
    #expect(repeated == repaired)
    #expect(services.transport.profilePayload?.updatedAt == repairedRevision)
  }

  @Test
  func testProfileAssignmentSurvivesTemporaryAbsenceAndExplicitRemovalPrunesIt() async throws {
    let services = try makeServices()
    _ = try await services.firstDevice.saveConnection(Self.connection, session: firstDeviceSession)
    let profiles = try await services.firstDevice.createProfile(
      name: "Work",
      appearance: MailProfileAppearance(colorName: "orange", symbolName: "briefcase"),
      session: firstDeviceSession
    )
    let workProfile = try requireValue(profiles.profiles.first(where: { $0.name == "Work" }))
    try await seedProfilePayload(
      MailProfileSyncPayload(
        assignments: [
          MailProfileConnectionAssignment(
            connectionId: Self.connection.id,
            profileId: workProfile.id
          )
        ],
        conflicts: [],
        defaultProfileId: profiles.defaultProfileId,
        profiles: profiles.profiles,
        schemaVersion: 1
      ),
      services: services
    )

    try await seedMailboxPayloadWithoutConnections(services: services)

    let absent = try await services.firstDevice.loadProfileSnapshot(session: firstDeviceSession)
    _ = try await services.firstDevice.saveConnection(Self.connection, session: firstDeviceSession)
    let restored = try await services.firstDevice.loadProfileSnapshot(session: firstDeviceSession)
    _ = try await services.firstDevice.removeConnection(
      Self.connection.id, session: firstDeviceSession)
    let removed = try await services.firstDevice.loadProfileSnapshot(session: firstDeviceSession)

    #expect(absent.assignments[Self.connection.id] == workProfile.id)
    #expect(restored.assignments[Self.connection.id] == workProfile.id)
    #expect(removed.assignments[Self.connection.id] == nil)
  }

  @Test
  func testProfileReadAcceptsMixedVersionValuesThisClientDoesNotWrite() async throws {
    let services = try makeServices()
    let migrated = try await services.firstDevice.loadProfileSnapshot(session: firstDeviceSession)
    var futureProfile = try requireValue(migrated.profiles.first)
    futureProfile.name = String(repeating: "x", count: 41)
    try await seedProfilePayload(
      MailProfileSyncPayload(
        assignments: [],
        conflicts: [],
        defaultProfileId: migrated.defaultProfileId,
        profiles: [futureProfile],
        schemaVersion: 1
      ),
      services: services
    )

    let loaded = try await services.secondDevice.loadProfileSnapshot(session: secondDeviceSession)

    #expect(loaded.profiles.first?.name == futureProfile.name)
  }

  @Test
  func testProfileScopedConnectionQueryRequiresAnExistingProfile() async throws {
    let services = try makeServices()
    _ = try await services.firstDevice.saveConnection(Self.connection, session: firstDeviceSession)
    _ = try await services.firstDevice.saveConnection(
      Self.otherConnection,
      session: firstDeviceSession
    )
    let profileSnapshot = try await services.firstDevice.loadProfileSnapshot(
      session: firstDeviceSession
    )

    let connections = try await services.firstDevice.loadConnections(
      in: profileSnapshot.defaultProfileId,
      session: firstDeviceSession
    )

    #expect(Set(connections.map(\.id)) == [Self.connection.id, Self.otherConnection.id])
    await #expect(throws: MailProfileSyncError.profileNotFound) {
      try await services.firstDevice.loadConnections(
        in: MailProfileId(rawValue: "missing-profile"),
        session: firstDeviceSession
      )
    }
  }

  @Test
  func testNonOverlappingProfileEditsMergeAndSameFieldEditsCreateConflictCopies()
    async throws
  {
    let services = try makeServices()
    let migrated = try await services.firstDevice.loadProfileSnapshot(session: firstDeviceSession)
    let base = try requireValue(migrated.profiles.first)
    var renamed = base
    renamed.name = "Personal"
    _ = try await services.firstDevice.saveProfile(
      renamed,
      basedOn: base,
      session: firstDeviceSession
    )
    var restyled = base
    restyled.appearance = MailProfileAppearance(colorName: "purple", symbolName: "briefcase")

    let merged = try await services.secondDevice.saveProfile(
      restyled,
      basedOn: base,
      session: secondDeviceSession
    )
    let mergedProfile = try requireValue(merged.profiles.first)

    #expect(mergedProfile.name == "Personal")
    #expect(mergedProfile.appearance == restyled.appearance)
    #expect(merged.conflicts.isEmpty)

    var competingRename = base
    competingRename.name = "Work"
    let conflicted = try await services.secondDevice.saveProfile(
      competingRename,
      basedOn: base,
      session: secondDeviceSession
    )
    let conflict = try requireValue(conflicted.conflicts.first)

    #expect(conflicted.profiles.first?.name == "Personal")
    #expect(conflict.field == .name)
    #expect(conflict.competingValue == .name("Work"))
    #expect(conflict.synchronizedValue == .name("Personal"))

    let resolved = try await services.firstDevice.resolveProfileConflict(
      conflict.id,
      useCompetingValue: true,
      session: firstDeviceSession
    )
    #expect(resolved.profiles.first?.name == "Work")
    #expect(resolved.conflicts.isEmpty)
  }

  @Test
  func testProfileNamesUseTheDedicatedValidationError() async throws {
    let services = try makeServices()

    await #expect(throws: MailProfileSyncError.invalidProfileName) {
      try await services.firstDevice.createProfile(
        name: String(repeating: "x", count: 41),
        appearance: .default,
        session: firstDeviceSession
      )
    }
    let profiles = try await services.firstDevice.createProfile(
      name: "Work",
      appearance: .default,
      session: firstDeviceSession
    )
    let base = try requireValue(
      profiles.profiles.first(where: { $0.id == profiles.defaultProfileId })
    )
    var duplicate = base
    duplicate.name = "Work"

    await #expect(throws: MailProfileSyncError.invalidProfileName) {
      try await services.firstDevice.saveProfile(
        duplicate,
        basedOn: base,
        session: firstDeviceSession
      )
    }
  }

  @Test
  func testMismatchedConflictValueDoesNotRemoveTheConflict() async throws {
    let services = try makeServices()
    let migrated = try await services.firstDevice.loadProfileSnapshot(session: firstDeviceSession)
    let profile = try requireValue(migrated.profiles.first)
    let conflict = MailProfileConflictCopy(
      baseValue: .name(profile.name),
      competingValue: .appearance(.default),
      field: .name,
      id: "mismatched-conflict",
      profileId: profile.id,
      synchronizedValue: .name(profile.name)
    )
    try await seedProfilePayload(
      MailProfileSyncPayload(
        assignments: [],
        conflicts: [conflict],
        defaultProfileId: migrated.defaultProfileId,
        profiles: migrated.profiles,
        schemaVersion: 1
      ),
      services: services
    )

    await #expect(throws: MailProfileSyncError.invalidProfileState) {
      try await services.firstDevice.resolveProfileConflict(
        conflict.id,
        useCompetingValue: true,
        session: firstDeviceSession
      )
    }
    let unchanged = try await services.firstDevice.loadProfileSnapshot(session: firstDeviceSession)
    #expect(unchanged.conflicts == [conflict])
  }

  @Test
  func testNewProfileUsesAnOpaqueScopeWhileTheDefaultRetainsLegacyRecords() async throws {
    let services = try makeServices()

    let snapshot = try await services.firstDevice.createProfile(
      name: "Work",
      appearance: MailProfileAppearance(colorName: "orange", symbolName: "briefcase"),
      session: firstDeviceSession
    )
    let defaultProfile = try requireValue(
      snapshot.profiles.first(where: { $0.id == snapshot.defaultProfileId })
    )
    let work = try requireValue(snapshot.profiles.first(where: { $0.name == "Work" }))

    #expect(snapshot.profiles.count == 2)
    #expect(defaultProfile.recordScope == .legacyProductAccount)
    #expect(
      work.recordScope.productSyncIdentifier("compose-preferences-primary")
        == "mail-profile-v1.\(work.id.rawValue).compose-preferences-primary"
    )
    #expect(work.id.rawValue != "Work")
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
        recordBoundary: ProductSyncRecordBoundary(
          keyMaterialStore: firstStore, transport: transport)
      ),
      firstKeyMaterialStore: firstStore,
      keyMaterial: keyMaterial,
      secondDevice: MailboxConnectionSyncService(
        cacheStore: InMemoryMailboxConnectionSyncCacheStore(),
        clock: clock,
        recordBoundary: ProductSyncRecordBoundary(
          keyMaterialStore: secondStore, transport: transport)
      ),
      transport: transport
    )
  }

  private struct Services {
    let firstDevice: MailboxConnectionSyncService
    let firstKeyMaterialStore: InMemoryProductSyncKeyMaterialStore
    let keyMaterial: ProductSyncKeyMaterial
    let secondDevice: MailboxConnectionSyncService
    let transport: RecordingMailboxConnectionSyncTransport
  }

  private func seedProfilePayload(
    _ payload: MailProfileSyncPayload,
    services: Services
  ) async throws {
    let encryptedPayload = try services.keyMaterial.encryptPayload(
      JSONEncoder().encode(payload),
      associatedData: Data(MailProfileSyncPayload.primaryIdentifier.utf8)
    )
    _ = try await services.transport.seedEncryptedProductSyncPayload(
      identityToken: firstDeviceSession.identityToken,
      payloadIdentifier: MailProfileSyncPayload.primaryIdentifier,
      encryptedPayload: encryptedPayload,
      trustedDeviceId: firstDeviceSession.trustedDeviceId
    )
  }

  private func workspaceSnapshot(
    defaultProfileId: MailProfileId,
    workProfileId: MailProfileId
  ) -> MailProfileSyncSnapshot {
    MailProfileSyncSnapshot(
      assignments: [
        Self.connection.id: defaultProfileId,
        Self.otherConnection.id: workProfileId,
      ],
      conflicts: [],
      defaultProfileId: defaultProfileId,
      profiles: [
        MailProfileDefinition(
          id: defaultProfileId,
          appearance: .default,
          name: "Personal",
          recordScope: .legacyProductAccount,
          quietState: .inactive
        ),
        MailProfileDefinition(
          id: workProfileId,
          appearance: MailProfileAppearance(colorName: "orange", symbolName: "briefcase"),
          name: "Work",
          recordScope: .profile(workProfileId),
          quietState: .inactive
        ),
      ],
      updatedAt: 1
    )
  }

  private func seedMailboxPayloadWithoutConnections(services: Services) async throws {
    let mailboxPayload = try requireValue(services.transport.payload)
    let plaintext = try services.keyMaterial.decryptPayload(
      mailboxPayload.encryptedPayload,
      associatedData: Data("mailbox-connections-primary".utf8)
    )
    var payload = try requireValue(JSONSerialization.jsonObject(with: plaintext) as? [String: Any])
    payload["connections"] = []
    payload["removals"] = []
    payload.removeValue(forKey: "defaultSendingConnectionProvider")
    payload.removeValue(forKey: "defaultSendingProviderAccountIdentifier")
    let encryptedPayload = try services.keyMaterial.encryptPayload(
      JSONSerialization.data(withJSONObject: payload),
      associatedData: Data("mailbox-connections-primary".utf8)
    )
    _ = try await services.transport.seedEncryptedProductSyncPayload(
      identityToken: firstDeviceSession.identityToken,
      payloadIdentifier: "mailbox-connections-primary",
      encryptedPayload: encryptedPayload,
      trustedDeviceId: firstDeviceSession.trustedDeviceId
    )
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
  @Test
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
      recordBoundary: ProductSyncRecordBoundary(
        keyMaterialStore: keyMaterialStore, transport: transport)
    )

    do {
      _ = try await service.saveConnection(Self.connection, session: firstDeviceSession)
      Issue.record("Expected the missing Product Sync key to prevent a new mailbox write")
    } catch let error as MailboxConnectionSyncError {
      #expect(error == .missingProductSyncKeyMaterial)
    }
    #expect(transport.payload == nil)
  }

  @Test
  func testProfileWriteRejectsMissingProductSyncKeyMaterial() async throws {
    let services = try makeServices()
    let snapshot = try await services.firstDevice.loadProfileSnapshot(session: firstDeviceSession)
    let base = try requireValue(snapshot.profiles.first)
    var renamed = base
    renamed.name = "Renamed"
    try services.firstKeyMaterialStore.clear(productAccountId: firstDeviceSession.productAccountId)

    await #expect(throws: MailProfileSyncError.missingProductSyncKeyMaterial) {
      try await services.firstDevice.saveProfile(
        renamed,
        basedOn: base,
        session: firstDeviceSession
      )
    }
  }
}
// swiftlint:enable type_body_length

private actor ControlledProfileSnapshotLoader: MailProfileSnapshotLoading {
  private var continuations: [Int: CheckedContinuation<MailProfileSyncSnapshot, any Error>] = [:]
  private var requestCount = 0

  func loadProfileSnapshot(
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailProfileSyncSnapshot {
    let request = requestCount
    requestCount += 1
    return try await withCheckedThrowingContinuation { continuation in
      continuations[request] = continuation
    }
  }

  func waitForRequestCount(_ expectedCount: Int) async {
    while requestCount < expectedCount {
      await Task.yield()
    }
  }

  func resumeRequest(_ request: Int, with snapshot: MailProfileSyncSnapshot) {
    continuations.removeValue(forKey: request)?.resume(returning: snapshot)
  }
}

private actor ControlledProfileActivationGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var isBlocked = false

  func wait() async {
    await withCheckedContinuation { continuation in
      isBlocked = true
      self.continuation = continuation
    }
  }

  func waitUntilBlocked() async {
    while !isBlocked {
      await Task.yield()
    }
  }

  func release() {
    continuation?.resume()
    continuation = nil
  }
}

private struct InMemoryMailProfileStartupStore: MailProfileStartupSelectionPersisting {
  func load(productAccountId _: String) -> MailProfileId? { nil }
  func save(_: MailProfileId, productAccountId _: String) {}
}

private final class RecordingMailboxConnectionSyncTransport: ProductSyncRecordTransport {
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
  var profilePayload: EncryptedProductSyncPayload? {
    payloads["mail-profiles-primary"]
  }
  private var payloads: [String: EncryptedProductSyncPayload] = [:]
  private var generationWriteCount = 0
  private var updatedAt: Int64 = 1_781_200_000_000

  func listEncryptedProductSyncPayloads(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifierPrefix: String,
    cursor: String?,
    limit: Int
  ) async throws -> EncryptedProductSyncPayloadPage {
    let matching = (additionalPayloads + payloads.values)
      .filter { $0.payloadIdentifier.hasPrefix(payloadIdentifierPrefix) }
      .sorted { $0.payloadIdentifier < $1.payloadIdentifier }
    let start = min(Int(cursor ?? "") ?? 0, matching.count)
    let end = min(start + limit, matching.count)
    return EncryptedProductSyncPayloadPage(
      continueCursor: end == matching.count ? "" : String(end),
      isDone: end == matching.count,
      page: Array(matching[start..<end])
    )
  }

  func getEncryptedProductSyncPayloads(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifiers: [String]
  ) async throws -> [EncryptedProductSyncPayload] {
    if let loadError { throw loadError }
    for identifier in payloadIdentifiers {
      if let error = payloadLoadErrors[identifier] { throw error }
    }
    return payloadIdentifiers.compactMap { payloads[$0] }
  }

  func seedEncryptedProductSyncPayload(
    identityToken _: String,
    payloadIdentifier: String,
    encryptedPayload: ProductSyncEncryptedPayload,
    trustedDeviceId _: String
  ) async throws -> EncryptedProductSyncPayload {
    write(payloadIdentifier: payloadIdentifier, encryptedPayload: encryptedPayload)
  }

  func putEncryptedProductSyncPayloadIfUnchanged(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifier: String,
    encryptedPayload: ProductSyncEncryptedPayload,
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
      return try requireValue(existing)
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

private enum MailboxConnectionSyncTestError: Error, Equatable {
  case expectedRemoval
  case unavailable
}

private actor ProviderAccessConcurrencyTransport: ProductSyncRecordTransport {
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
    session _: ProductAccountSessionSnapshot,
    payloadIdentifierPrefix _: String,
    cursor _: String?,
    limit _: Int
  ) async throws -> EncryptedProductSyncPayloadPage {
    EncryptedProductSyncPayloadPage(continueCursor: "", isDone: true, page: [])
  }

  func getEncryptedProductSyncPayloads(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifiers _: [String]
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

  func putEncryptedProductSyncPayloadIfUnchanged(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifier _: String,
    encryptedPayload _: ProductSyncEncryptedPayload,
    expectedUpdatedAt _: Int64?
  ) async throws -> EncryptedProductSyncPayload {
    throw MailboxConnectionSyncTestError.unavailable
  }
}
