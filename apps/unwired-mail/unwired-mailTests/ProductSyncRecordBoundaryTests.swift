import CryptoKit
import Foundation
import Testing

@testable import unwired_mail

// swiftlint:disable file_length type_body_length

@Suite(.serialized)
final class ProductSyncRecordBoundaryTests {
  private struct Preference: Codable, Equatable, Sendable {
    let title: String
  }

  private let session = ProductAccountSessionSnapshot(
    appleUserIdentifier: "apple-user-preview",
    identityToken: "apple-token",
    productAccountId: "productAccountFixtureId",
    trustedDeviceId: "trustedDeviceFixtureId"
  )

  @Test
  func testSingletonWritesAndReadsTypedValueWithOpaqueRevision() async throws {
    let keyMaterialStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    let boundary = ProductSyncRecordBoundary(
      keyMaterialStore: keyMaterialStore,
      transport: InMemoryProductSyncRecordTransport()
    )
    let handle = boundary.singleton(
      ProductSyncSingletonDefinition<Preference>(
        identifier: "test-preference",
        cachePolicy: .authoritative
      )
    )

    let written = try await handle.update(session: session) { current in
      #expect(current == nil)
      return .write(Preference(title: "Important"))
    }
    let loaded = try await handle.read(session: session)

    #expect(written?.value == Preference(title: "Important"))
    #expect(loaded?.value == Preference(title: "Important"))
    #expect(written?.revision == loaded?.revision)
  }

  @Test
  func testUpdateReloadsConflictAndLetsDomainAcceptAuthoritativeValue() async throws {
    let keyMaterialStore = try keyedStore()
    let material = try requireValue(
      try keyMaterialStore.load(productAccountId: session.productAccountId))
    let identifier = "test-preference"
    let authoritativeValue = Preference(title: "Authoritative")
    let authoritativePayload = EncryptedProductSyncPayload(
      encryptedPayload: try material.encryptPayload(
        JSONEncoder().encode(authoritativeValue),
        associatedData: Data(identifier.utf8)
      ),
      payloadIdentifier: identifier,
      updatedAt: 2
    )
    let transport = ConflictOnceProductSyncRecordTransport(
      authoritativePayload: authoritativePayload
    )
    let handle = ProductSyncRecordBoundary(
      keyMaterialStore: keyMaterialStore,
      retryDelay: { _ in },
      transport: transport
    ).singleton(
      ProductSyncSingletonDefinition<Preference>(
        identifier: identifier,
        cachePolicy: .authoritative
      )
    )
    var decisions: [Preference?] = []

    let result = try await handle.update(session: session) { current in
      decisions.append(current?.value)
      return current == nil ? .write(Preference(title: "Proposed")) : .acceptAuthoritative
    }

    #expect(decisions == [nil, authoritativeValue])
    #expect(result?.value == authoritativeValue)
    let writeCount = await transport.writeCount()
    #expect(writeCount == 1)
  }

  @Test
  func testFamilyListsEveryCursorPageAndReadsExactTypedIdentifiers() async throws {
    let cache = InMemoryProductSyncCiphertextCache()
    let keyMaterialStore = try keyedStore()
    let transport = InMemoryProductSyncRecordTransport(pageSize: 2)
    let family = ProductSyncRecordBoundary(
      cache: cache,
      keyMaterialStore: keyMaterialStore,
      transport: transport
    ).family(
      ProductSyncRecordFamilyDefinition<String, Preference>(
        identifier: { "test-preference:\($0)" },
        identifierPrefix: "test-preference:",
        recordId: { String($0.dropFirst("test-preference:".count)) },
        cachePolicy: .authoritativeWithCiphertextFallback
      )
    )
    for identifier in ["one", "two", "three"] {
      _ = try await family.update(identifier, session: session) { _ in
        .write(Preference(title: identifier.capitalized))
      }
    }

    let listed = try await family.list(session: session)
    let exact = try await family.read(["one", "three"], session: session)

    #expect(listed["one"]?.value == Preference(title: "One"))
    #expect(listed["two"]?.value == Preference(title: "Two"))
    #expect(listed["three"]?.value == Preference(title: "Three"))
    #expect(exact["one"]?.value == Preference(title: "One"))
    #expect(exact["three"]?.value == Preference(title: "Three"))
    #expect(exact["two"] == nil)

    let offlineList = try await ProductSyncRecordBoundary(
      cache: cache,
      keyMaterialStore: keyMaterialStore,
      transport: FailingProductSyncRecordTransport()
    ).family(
      ProductSyncRecordFamilyDefinition<String, Preference>(
        identifier: { "test-preference:\($0)" },
        identifierPrefix: "test-preference:",
        recordId: { String($0.dropFirst("test-preference:".count)) },
        cachePolicy: .authoritativeWithCiphertextFallback
      )
    ).list(session: session)
    #expect(offlineList["one"]?.value == Preference(title: "One"))
    #expect(offlineList["two"]?.value == Preference(title: "Two"))
    #expect(offlineList["three"]?.value == Preference(title: "Three"))
  }

  @Test
  func testUpdatesSerializePerAccountRecordWhileDistinctRecordsStayConcurrent() async throws {
    let transport = SuspendingProductSyncRecordTransport()
    let boundary = ProductSyncRecordBoundary(
      keyMaterialStore: try keyedStore(),
      retryDelay: { _ in },
      transport: transport
    )
    let first = boundary.singleton(
      ProductSyncSingletonDefinition<Preference>(
        identifier: "test-preference:first",
        cachePolicy: .authoritative
      )
    )
    let second = boundary.singleton(
      ProductSyncSingletonDefinition<Preference>(
        identifier: "test-preference:second",
        cachePolicy: .authoritative
      )
    )

    async let firstWrite = first.update(session: session) { _ in
      .write(Preference(title: "First"))
    }
    async let competingFirstWrite = first.update(session: session) { _ in
      .write(Preference(title: "Competing"))
    }
    async let secondWrite = second.update(session: session) { _ in
      .write(Preference(title: "Second"))
    }
    _ = try await (firstWrite, competingFirstWrite, secondWrite)
    let metrics = await transport.metrics()

    #expect(metrics.maximumByIdentifier["test-preference:first"] == 1)
    #expect(metrics.maximumTotal >= 2)
  }

  @Test
  func testCancelledQueuedUpdateNeverStartsTransportRead() async throws {
    let transport = LockHoldingProductSyncRecordTransport()
    let boundary = ProductSyncRecordBoundary(
      keyMaterialStore: try keyedStore(),
      retryDelay: { _ in },
      transport: transport
    )
    let handle = boundary.singleton(
      ProductSyncSingletonDefinition<Preference>(
        identifier: "test-preference",
        cachePolicy: .authoritative
      )
    )
    let first = Task {
      try await handle.update(session: session) { _ in .write(Preference(title: "First")) }
    }
    await transport.waitUntilWriteHeld()
    let second = Task {
      try await handle.update(session: session) { _ in .write(Preference(title: "Second")) }
    }
    let lock = await boundary.lockRegistry.lock(
      for: ProductSyncRecordKey(
        productAccountId: session.productAccountId,
        payloadIdentifier: "test-preference"
      )
    )
    await lock.waitUntilQueued()
    second.cancel()
    await transport.releaseWrite()
    _ = try await first.value

    do {
      _ = try await second.value
      Issue.record("Expected cancellation")
    } catch is CancellationError {}
    let readCount = await transport.readCount()
    #expect(readCount == 1)
  }

  @Test
  func testCachedBoundarySharesRecordLockRegistry() {
    let boundary = ProductSyncRecordBoundary()

    let cached = boundary.caching(InMemoryProductSyncCiphertextCache())

    #expect(cached.lockRegistry === boundary.lockRegistry)
  }

  @Test
  func testPermittedCiphertextFallbackReadsCachedAuthoritativePayload() async throws {
    let cache = InMemoryProductSyncCiphertextCache()
    let keyMaterialStore = try keyedStore()
    let definition = ProductSyncSingletonDefinition<Preference>(
      identifier: "test-preference",
      cachePolicy: .authoritativeWithCiphertextFallback
    )
    let writableHandle = ProductSyncRecordBoundary(
      cache: cache,
      keyMaterialStore: keyMaterialStore,
      transport: InMemoryProductSyncRecordTransport()
    ).singleton(definition)
    _ = try await writableHandle.update(session: session) { _ in
      .write(Preference(title: "Cached"))
    }
    let offlineHandle = ProductSyncRecordBoundary(
      cache: cache,
      keyMaterialStore: keyMaterialStore,
      transport: FailingProductSyncRecordTransport()
    ).singleton(definition)

    let loaded = try await offlineHandle.read(session: session)

    #expect(loaded?.value == Preference(title: "Cached"))
  }

  @Test
  func testPermittedCiphertextFallbackReadsCachedFamilyRecord() async throws {
    let cache = InMemoryProductSyncCiphertextCache()
    let keyMaterialStore = try keyedStore()
    let definition = ProductSyncRecordFamilyDefinition<String, Preference>(
      identifier: { "test-preference:\($0)" },
      identifierPrefix: "test-preference:",
      recordId: { String($0.dropFirst("test-preference:".count)) },
      cachePolicy: .authoritativeWithCiphertextFallback
    )
    let writableFamily = ProductSyncRecordBoundary(
      cache: cache,
      keyMaterialStore: keyMaterialStore,
      transport: InMemoryProductSyncRecordTransport()
    ).family(definition)
    _ = try await writableFamily.update("one", session: session) { _ in
      .write(Preference(title: "Cached"))
    }
    let offlineFamily = ProductSyncRecordBoundary(
      cache: cache,
      keyMaterialStore: keyMaterialStore,
      transport: FailingProductSyncRecordTransport()
    ).family(definition)

    let loaded = try await offlineFamily.read(["one"], session: session)

    #expect(loaded["one"]?.value == Preference(title: "Cached"))
  }

  @Test
  func testFamilyReadStopsAfterCancellationWhileProcessingTransportResults() async throws {
    let family = ProductSyncRecordBoundary(
      cache: CancellingProductSyncCiphertextCache(),
      transport: ReturningProductSyncRecordTransport()
    ).family(
      ProductSyncRecordFamilyDefinition<String, Preference>(
        identifier: { "test-preference:\($0)" },
        identifierPrefix: "test-preference:",
        recordId: { String($0.dropFirst("test-preference:".count)) },
        cachePolicy: .authoritativeWithCiphertextFallback
      )
    )

    let readTask = Task {
      try await family.read(["one", "two"], session: session)
    }

    do {
      _ = try await readTask.value
      Issue.record("Expected cancellation")
    } catch is CancellationError {
    }
  }

  @Test
  func testRepeatedConflictsStopAfterFiveConditionalWrites() async throws {
    let keyMaterialStore = try keyedStore()
    let material = try requireValue(
      try keyMaterialStore.load(productAccountId: session.productAccountId))
    let identifier = "test-preference"
    let conflict = EncryptedProductSyncPayload(
      encryptedPayload: try material.encryptPayload(
        JSONEncoder().encode(Preference(title: "Conflict")),
        associatedData: Data(identifier.utf8)
      ),
      payloadIdentifier: identifier,
      updatedAt: 2
    )
    let transport = ConflictOnceProductSyncRecordTransport(authoritativePayload: conflict)
    let handle = ProductSyncRecordBoundary(
      keyMaterialStore: keyMaterialStore,
      retryDelay: { _ in },
      transport: transport
    ).singleton(
      ProductSyncSingletonDefinition<Preference>(
        identifier: identifier,
        cachePolicy: .authoritative
      )
    )

    do {
      _ = try await handle.update(session: session) { _ in
        .write(Preference(title: "Proposed"))
      }
      Issue.record("Expected retry limit")
    } catch let error as ProductSyncRecordBoundaryError {
      #expect(error == .retryLimitExceeded)
    }
    let writeCount = await transport.writeCount()
    #expect(writeCount == 5)
  }

  @Test
  func testWriteWithoutExistingKeyMaterialFailsBeforeTransport() async throws {
    let transport = CountingProductSyncRecordTransport()
    let handle = ProductSyncRecordBoundary(
      keyMaterialStore: InMemoryProductSyncKeyMaterialStore(),
      transport: transport
    ).singleton(
      ProductSyncSingletonDefinition<Preference>(
        identifier: "test-preference",
        cachePolicy: .authoritative
      )
    )

    do {
      _ = try await handle.update(session: session) { _ in
        .write(Preference(title: "Must not write"))
      }
      Issue.record("Expected missing key material")
    } catch let error as ProductSyncRecordBoundaryError {
      #expect(error == .missingProductSyncKeyMaterial)
    }
    let writeCount = await transport.writeCount()
    #expect(writeCount == 0)
  }

  @Test
  func testWriteAccessValidationRequiresExistingKeyMaterial() throws {
    let handle = ProductSyncRecordBoundary(
      keyMaterialStore: InMemoryProductSyncKeyMaterialStore(),
      transport: InMemoryProductSyncRecordTransport()
    ).singleton(
      ProductSyncSingletonDefinition<Preference>(
        identifier: "test-preference",
        cachePolicy: .authoritative
      )
    )

    #expect {
      try handle.validateWriteAccess(session: session)
    } throws: { error in
      #expect(error as? ProductSyncRecordBoundaryError == .missingProductSyncKeyMaterial)
      return true
    }
  }

  @Test
  func testInvalidateThenRefreshDoesNotRetainUnreadCiphertext() async throws {
    let cache = RecordingProductSyncCiphertextCache()
    let handle = ProductSyncRecordBoundary(
      cache: cache,
      keyMaterialStore: try keyedStore(),
      transport: InMemoryProductSyncRecordTransport()
    ).singleton(
      ProductSyncSingletonDefinition<Preference>(
        identifier: "test-preference",
        cachePolicy: .invalidateThenRefresh
      )
    )

    _ = try await handle.update(session: session) { _ in
      .write(Preference(title: "Committed"))
    }

    let events = await cache.events()
    #expect(events == ["remove"])
  }

  @Test
  func testRefreshAfterCommitSavesCommittedCiphertext() async throws {
    let cache = RecordingProductSyncCiphertextCache()
    let keyMaterialStore = try keyedStore()
    let transport = InMemoryProductSyncRecordTransport()
    let definition = ProductSyncSingletonDefinition<Preference>(
      identifier: "test-preference",
      cachePolicy: .refreshAfterCommit
    )
    let handle = ProductSyncRecordBoundary(
      cache: cache,
      keyMaterialStore: keyMaterialStore,
      transport: transport
    ).singleton(definition)

    _ = try await handle.update(session: session) { _ in
      .write(Preference(title: "Initial"))
    }
    await cache.resetEvents()

    _ = try await handle.update(session: session) { _ in
      .write(Preference(title: "Committed"))
    }

    let events = await cache.events()
    #expect(events == ["save"])
    let offlineHandle = ProductSyncRecordBoundary(
      cache: cache,
      keyMaterialStore: keyMaterialStore,
      transport: FailingProductSyncRecordTransport()
    ).singleton(
      ProductSyncSingletonDefinition<Preference>(
        identifier: "test-preference",
        cachePolicy: .authoritativeWithCiphertextFallback
      )
    )
    let loaded = try await offlineHandle.read(session: session)
    #expect(loaded?.value == Preference(title: "Committed"))
  }

  @Test
  func testInMemoryTransportScopesIdenticalIdentifiersByProductAccount() async throws {
    let otherSession = ProductAccountSessionSnapshot(
      appleUserIdentifier: "other-user",
      identityToken: "other-token",
      productAccountId: "other-account",
      trustedDeviceId: "other-device"
    )
    let keyMaterialStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: otherSession.productAccountId,
      allowCreation: true
    )
    let cache = InMemoryProductSyncCiphertextCache()
    let transport = InMemoryProductSyncRecordTransport()
    let handle = ProductSyncRecordBoundary(
      cache: cache,
      keyMaterialStore: keyMaterialStore,
      transport: transport
    ).singleton(
      ProductSyncSingletonDefinition<Preference>(
        identifier: "test-preference",
        cachePolicy: .authoritativeWithCiphertextFallback
      )
    )
    _ = try await handle.update(session: session) { _ in
      .write(Preference(title: "First account"))
    }
    _ = try await handle.update(session: otherSession) { _ in
      .write(Preference(title: "Other account"))
    }

    let offlineHandle = ProductSyncRecordBoundary(
      cache: cache,
      keyMaterialStore: keyMaterialStore,
      transport: FailingProductSyncRecordTransport()
    ).singleton(
      ProductSyncSingletonDefinition<Preference>(
        identifier: "test-preference",
        cachePolicy: .authoritativeWithCiphertextFallback
      )
    )
    let firstAccount = try await offlineHandle.read(session: session)?.value.title
    let secondAccount = try await offlineHandle.read(session: otherSession)?.value.title

    #expect(firstAccount == "First account")
    #expect(secondAccount == "Other account")
  }

  @Test
  func testIncompleteFamilyPaginationDoesNotReplaceCache() async throws {
    for cursorMode in [PaginatedTestTransport.CursorMode.missing, .repeated] {
      let cache = RecordingProductSyncCiphertextCache()
      let family = ProductSyncRecordBoundary(
        cache: cache,
        transport: PaginatedTestTransport(cursorMode: cursorMode)
      ).family(
        ProductSyncRecordFamilyDefinition<String, Preference>(
          identifier: { "test-preference:\($0)" },
          identifierPrefix: "test-preference:",
          recordId: { String($0.dropFirst("test-preference:".count)) },
          cachePolicy: .authoritativeWithCiphertextFallback
        )
      )

      do {
        _ = try await family.list(session: session)
        Issue.record("Expected incomplete pagination")
      } catch let error as ProductSyncRecordBoundaryError {
        #expect(error == .incompletePagination)
      }
      let cacheEvents = await cache.events()
      #expect(!(cacheEvents.contains("replaceFamily")))
    }
  }

  @Test
  func testFamilyPaginationStopsAfterTheMaximumPageCount() async throws {
    let boundary = ProductSyncRecordBoundary(
      maximumListPages: 2,
      transport: PaginatedTestTransport(cursorMode: .unbounded)
    )

    await #expect(throws: ProductSyncRecordBoundaryError.incompletePagination) {
      try await boundary.listEncryptedPayloads(
        session: session,
        identifierPrefix: "test-preference:"
      )
    }
  }

  @Test
  func testFamilyListSkipsPrefixCollisionsThatDoNotRoundTrip() async throws {
    let keyMaterialStore = try keyedStore()
    let material = try requireValue(
      try keyMaterialStore.load(productAccountId: session.productAccountId))
    let validIdentifier = "test-preference:one"
    let valid = EncryptedProductSyncPayload(
      encryptedPayload: try material.encryptPayload(
        JSONEncoder().encode(Preference(title: "One")),
        associatedData: Data(validIdentifier.utf8)
      ),
      payloadIdentifier: validIdentifier,
      updatedAt: 1
    )
    let collision = EncryptedProductSyncPayload(
      encryptedPayload: valid.encryptedPayload,
      payloadIdentifier: "test-preference:nested:other",
      updatedAt: 1
    )
    let family = ProductSyncRecordBoundary(
      keyMaterialStore: keyMaterialStore,
      transport: FixedProductSyncRecordTransport(payloads: [valid, collision])
    ).family(
      ProductSyncRecordFamilyDefinition<String, Preference>(
        identifier: { "test-preference:\($0)" },
        identifierPrefix: "test-preference:",
        recordId: {
          let suffix = String($0.dropFirst("test-preference:".count))
          return suffix.contains(":") ? nil : suffix
        },
        cachePolicy: .authoritative
      )
    )

    let listed = try await family.list(session: session)

    #expect(Set(listed.keys) == ["one"])
    #expect(listed["one"]?.value == Preference(title: "One"))
  }

  @Test
  func testIdentifierBindingRejectsCiphertextFromAnotherRecord() async throws {
    let keyMaterialStore = try keyedStore()
    let material = try requireValue(
      try keyMaterialStore.load(productAccountId: session.productAccountId))
    let payload = EncryptedProductSyncPayload(
      encryptedPayload: try material.encryptPayload(
        JSONEncoder().encode(Preference(title: "Wrong record")),
        associatedData: Data("test-preference:other".utf8)
      ),
      payloadIdentifier: "test-preference:one",
      updatedAt: 1
    )
    let family = ProductSyncRecordBoundary(
      keyMaterialStore: keyMaterialStore,
      transport: FixedProductSyncRecordTransport(payloads: [payload])
    ).family(
      ProductSyncRecordFamilyDefinition<String, Preference>(
        identifier: { "test-preference:\($0)" },
        identifierPrefix: "test-preference:",
        recordId: { String($0.dropFirst("test-preference:".count)) },
        cachePolicy: .authoritative
      )
    )

    do {
      _ = try await family.read(["one"], session: session)
      Issue.record("Expected identifier-bound decryption failure")
    } catch {}
  }

  @Test
  func testCancellationStopsConditionalWriteRetry() async throws {
    let keyMaterialStore = try keyedStore()
    let material = try requireValue(
      try keyMaterialStore.load(productAccountId: session.productAccountId))
    let conflict = EncryptedProductSyncPayload(
      encryptedPayload: try material.encryptPayload(
        JSONEncoder().encode(Preference(title: "Conflict")),
        associatedData: Data("test-preference".utf8)
      ),
      payloadIdentifier: "test-preference",
      updatedAt: 2
    )
    let transport = ConflictOnceProductSyncRecordTransport(authoritativePayload: conflict)
    let handle = ProductSyncRecordBoundary(
      keyMaterialStore: keyMaterialStore,
      retryDelay: { _ in throw CancellationError() },
      transport: transport
    ).singleton(
      ProductSyncSingletonDefinition<Preference>(
        identifier: "test-preference",
        cachePolicy: .authoritative
      )
    )

    do {
      _ = try await handle.update(session: session) { _ in
        .write(Preference(title: "Proposed"))
      }
      Issue.record("Expected cancellation")
    } catch is CancellationError {}
    let writeCount = await transport.writeCount()
    #expect(writeCount == 1)
  }

  @Test
  func testExactFamilyReadsBatchWithBoundedConcurrency() async throws {
    let transport = BatchingProductSyncRecordTransport()
    let family = ProductSyncRecordBoundary(transport: transport).family(
      ProductSyncRecordFamilyDefinition<Int, Preference>(
        identifier: { "test-preference:\($0)" },
        identifierPrefix: "test-preference:",
        recordId: { Int($0.dropFirst("test-preference:".count)) },
        cachePolicy: .authoritative
      )
    )

    let records = try await family.read(Array(0..<205), session: session)
    let metrics = await transport.metrics()

    #expect(records.isEmpty)
    #expect(metrics.batchSizes.sorted() == [5, 100, 100])
    #expect(metrics.maximumConcurrentReads > 1)
    #expect(metrics.maximumConcurrentReads <= 4)
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testKeyedFamilyOwnsIdentifierDerivationAndMirrorsExistingKeyVersions() async throws {
    let keyMaterialStore = InMemoryProductSyncKeyMaterialStore()
    let original = try keyMaterialStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    let transport = InMemoryProductSyncRecordTransport()
    let family = ProductSyncRecordBoundary(
      keyMaterialStore: keyMaterialStore,
      transport: transport
    ).keyedFamily(
      ProductSyncKeyedRecordFamilyDefinition<String, Preference>(
        identifierData: { Data($0.utf8) },
        identifierPrefix: "test-keyed-preference:",
        cachePolicy: .authoritative
      )
    )
    let recordId = "sender@example.com"
    try await family.update(recordId, session: session) { existing in
      #expect(existing.isEmpty)
      return .write(Preference(title: "Original"))
    }
    let rotated = try original.rotatingAccountKey(
      toVersion: 2,
      accountKeyData: Data(repeating: 7, count: ProductSyncKeyMaterial.keyByteCount)
    )
    try keyMaterialStore.save(rotated, productAccountId: session.productAccountId)

    try await family.update(recordId, session: session) { existing in
      #expect(existing.map(\.value) == [Preference(title: "Original")])
      return .write(Preference(title: "Updated"))
    }

    let identifiers = [rotated.accountKeyData, original.accountKeyData].map { keyData in
      let digest = HMAC<SHA256>.authenticationCode(
        for: Data(recordId.utf8),
        using: SymmetricKey(data: keyData)
      )
      return "test-keyed-preference:" + digest.map { String(format: "%02x", $0) }.joined()
    }
    let payloads = try await transport.getEncryptedProductSyncPayloads(
      session: session,
      payloadIdentifiers: identifiers
    )
    let values = try payloads.map { payload in
      let plaintext = try rotated.decryptPayload(
        payload.encryptedPayload,
        associatedData: Data(payload.payloadIdentifier.utf8)
      )
      return try JSONDecoder().decode(Preference.self, from: plaintext)
    }

    #expect(Set(payloads.map(\.payloadIdentifier)) == Set(identifiers))
    #expect(values == [Preference(title: "Updated"), Preference(title: "Updated")])
    #expect(Set(payloads.map(\.encryptedPayload.keyVersion)) == [2])
  }

  @Test
  func testKeyedFamilyWritesOnlyCurrentIdentifierWhenLegacyRecordIsAbsent() async throws {
    let keyMaterialStore = InMemoryProductSyncKeyMaterialStore()
    let original = try keyMaterialStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    let rotated = try original.rotatingAccountKey(
      toVersion: 2,
      accountKeyData: Data(repeating: 7, count: ProductSyncKeyMaterial.keyByteCount)
    )
    try keyMaterialStore.save(rotated, productAccountId: session.productAccountId)
    let transport = InMemoryProductSyncRecordTransport()
    let family = ProductSyncRecordBoundary(
      keyMaterialStore: keyMaterialStore,
      transport: transport
    ).keyedFamily(
      ProductSyncKeyedRecordFamilyDefinition<String, Preference>(
        identifierData: { Data($0.utf8) },
        identifierPrefix: "test-keyed-preference:",
        cachePolicy: .authoritative
      )
    )
    let recordId = "sender@example.com"

    try await family.update(recordId, session: session) { existing in
      #expect(existing.isEmpty)
      return .write(Preference(title: "Current"))
    }

    let identifiers = [rotated.accountKeyData, original.accountKeyData].map { keyData in
      let digest = HMAC<SHA256>.authenticationCode(
        for: Data(recordId.utf8),
        using: SymmetricKey(data: keyData)
      )
      return "test-keyed-preference:" + digest.map { String(format: "%02x", $0) }.joined()
    }
    let payloads = try await transport.getEncryptedProductSyncPayloads(
      session: session,
      payloadIdentifiers: identifiers
    )

    #expect(payloads.map(\.payloadIdentifier) == [identifiers[0]])
    #expect(payloads.map(\.encryptedPayload.keyVersion) == [2])
  }

  @Test
  func testValidFamilyReadKeepsDecodableRecordsWhenAnotherPayloadIsCorrupt() async throws {
    let keyMaterialStore = try keyedStore()
    let material = try requireValue(
      try keyMaterialStore.load(productAccountId: session.productAccountId))
    let validIdentifier = "test-preference:valid"
    let corruptIdentifier = "test-preference:corrupt"
    let valid = EncryptedProductSyncPayload(
      encryptedPayload: try material.encryptPayload(
        JSONEncoder().encode(Preference(title: "Valid")),
        associatedData: Data(validIdentifier.utf8)
      ),
      payloadIdentifier: validIdentifier,
      updatedAt: 1
    )
    let corrupt = EncryptedProductSyncPayload(
      encryptedPayload: ProductSyncEncryptedPayload(
        algorithm: valid.encryptedPayload.algorithm,
        ciphertextBase64: "invalid",
        keyVersion: valid.encryptedPayload.keyVersion,
        nonceBase64: valid.encryptedPayload.nonceBase64,
        schemaVersion: valid.encryptedPayload.schemaVersion,
        tagBase64: valid.encryptedPayload.tagBase64
      ),
      payloadIdentifier: corruptIdentifier,
      updatedAt: 1
    )
    let family = ProductSyncRecordBoundary(
      keyMaterialStore: keyMaterialStore,
      transport: FixedProductSyncRecordTransport(payloads: [valid, corrupt])
    ).family(
      ProductSyncRecordFamilyDefinition<String, Preference>(
        identifier: { "test-preference:\($0)" },
        identifierPrefix: "test-preference:",
        recordId: { String($0.dropFirst("test-preference:".count)) },
        cachePolicy: .authoritative
      )
    )

    let records = try await family.readValid(["valid", "corrupt"], session: session)

    #expect(records["valid"]?.value == Preference(title: "Valid"))
    #expect(records["corrupt"] == nil)
  }

  @Test
  func testRefreshingReadCachesTheDomainTransformedTypedValue() async throws {
    let cache = InMemoryProductSyncCiphertextCache()
    let keyMaterialStore = try keyedStore()
    let transport = InMemoryProductSyncRecordTransport()
    let definition = ProductSyncSingletonDefinition<Preference>(
      identifier: "test-preference",
      cachePolicy: .authoritative
    )
    let handle = ProductSyncRecordBoundary(
      cache: cache,
      keyMaterialStore: keyMaterialStore,
      transport: transport
    ).singleton(definition)
    _ = try await handle.update(session: session) { _ in
      .write(Preference(title: "Authoritative"))
    }

    let refreshed = try await handle.readRefreshingCache(session: session) {
      Preference(title: "\($0.title) transformed")
    }
    let cached = try await ProductSyncRecordBoundary(
      cache: cache,
      keyMaterialStore: keyMaterialStore,
      transport: FailingProductSyncRecordTransport()
    ).singleton(
      ProductSyncSingletonDefinition<Preference>(
        identifier: "test-preference",
        cachePolicy: .authoritativeWithCiphertextFallback
      )
    ).read(session: session)

    #expect(refreshed?.value.title == "Authoritative transformed")
    #expect(cached?.value == refreshed?.value)
    #expect(cached?.revision == refreshed?.revision)
  }

  @Test
  func testRefreshingReadPropagatesCancellationAfterCacheSave() async throws {
    let keyMaterialStore = try keyedStore()
    let transport = InMemoryProductSyncRecordTransport()
    let definition = ProductSyncSingletonDefinition<Preference>(
      identifier: "test-preference",
      cachePolicy: .authoritative
    )
    _ = try await ProductSyncRecordBoundary(
      keyMaterialStore: keyMaterialStore,
      transport: transport
    ).singleton(definition).update(session: session) { _ in
      .write(Preference(title: "Authoritative"))
    }
    let handle = ProductSyncRecordBoundary(
      cache: CancellingProductSyncCiphertextCache(),
      keyMaterialStore: keyMaterialStore,
      transport: transport
    ).singleton(definition)

    let task = Task {
      try await handle.readRefreshingCache(session: session) { $0 }
    }

    do {
      _ = try await task.value
      Issue.record("Expected cancellation")
    } catch is CancellationError {}
  }

  @Test
  func testRelatedRefreshingReadPropagatesCacheLoadCancellation() async throws {
    let boundary = ProductSyncRecordBoundary(
      cache: CancellingProductSyncCiphertextCache(cancelOnLoad: true),
      transport: InMemoryProductSyncRecordTransport()
    )
    let handle = boundary.singleton(
      ProductSyncSingletonDefinition<Preference>(
        identifier: "test-preference",
        cachePolicy: .authoritative
      )
    )
    let other = boundary.singleton(
      ProductSyncSingletonDefinition<Preference>(
        identifier: "other-preference",
        cachePolicy: .authoritative
      )
    )

    do {
      _ = try await handle.readRefreshingCache(with: other, session: session) { value, _ in
        value
      }
      Issue.record("Expected cancellation")
    } catch is CancellationError {}
  }

  @Test
  func testEmptyRefreshingReadDoesNotRemoveCacheReplacedAfterReadStarted() async throws {
    let cache = InMemoryProductSyncCiphertextCache()
    let keyMaterialStore = try keyedStore()
    let material = try requireValue(
      try keyMaterialStore.load(productAccountId: session.productAccountId))
    let identifier = "test-preference"
    let initial = EncryptedProductSyncPayload(
      encryptedPayload: try material.encryptPayload(
        JSONEncoder().encode(Preference(title: "Initial")),
        associatedData: Data(identifier.utf8)
      ),
      payloadIdentifier: identifier,
      updatedAt: 1
    )
    let replacement = EncryptedProductSyncPayload(
      encryptedPayload: try material.encryptPayload(
        JSONEncoder().encode(Preference(title: "Replacement")),
        associatedData: Data(identifier.utf8)
      ),
      payloadIdentifier: identifier,
      updatedAt: 2
    )
    try await cache.save(initial, productAccountId: session.productAccountId)
    let handle = ProductSyncRecordBoundary(
      cache: cache,
      keyMaterialStore: keyMaterialStore,
      transport: CacheReplacingEmptyRecordTransport(
        cache: cache,
        productAccountId: session.productAccountId,
        replacement: replacement
      )
    ).singleton(
      ProductSyncSingletonDefinition<Preference>(
        identifier: identifier,
        cachePolicy: .authoritative
      )
    )

    let result = try await handle.readRefreshingCache(session: session) { $0 }
    let cached = try await handle.readCached(session: session)

    #expect(result == nil)
    #expect(cached?.value == Preference(title: "Replacement"))
    #expect(cached?.revision.legacyUpdatedAt == 2)
  }

  @Test
  func testMailboxCiphertextCacheDoesNotReplaceNewerPayload() async throws {
    let store = InMemoryMailboxConnectionSyncCacheStore()
    let cache = MailboxConnectionSyncCiphertextCache(store: store)
    let encryptedPayload = ProductSyncEncryptedPayload(
      algorithm: ProductSyncEncryptedPayload.algorithmName,
      ciphertextBase64: "unused",
      keyVersion: 1,
      nonceBase64: "unused",
      schemaVersion: 1,
      tagBase64: "unused"
    )
    for updatedAt in [Int64(42), 41] {
      try await cache.save(
        EncryptedProductSyncPayload(
          encryptedPayload: encryptedPayload,
          payloadIdentifier: MailboxConnectionSyncPayload.primaryIdentifier,
          updatedAt: updatedAt
        ),
        productAccountId: session.productAccountId
      )
    }

    let cached = try await cache.load(
      productAccountId: session.productAccountId,
      payloadIdentifier: MailboxConnectionSyncPayload.primaryIdentifier
    )
    #expect(cached?.updatedAt == 42)
  }

  private func keyedStore() throws -> InMemoryProductSyncKeyMaterialStore {
    let store = InMemoryProductSyncKeyMaterialStore()
    _ = try store.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    return store
  }
}

private struct CacheReplacingEmptyRecordTransport: ProductSyncRecordTransport {
  let cache: InMemoryProductSyncCiphertextCache
  let productAccountId: String
  let replacement: EncryptedProductSyncPayload

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
    try await cache.save(replacement, productAccountId: productAccountId)
    return []
  }

  func putEncryptedProductSyncPayloadIfUnchanged(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifier _: String,
    encryptedPayload _: ProductSyncEncryptedPayload,
    expectedUpdatedAt _: Int64?
  ) async throws -> EncryptedProductSyncPayload {
    throw URLError(.unsupportedURL)
  }
}

private actor BatchingProductSyncRecordTransport: ProductSyncRecordTransport {
  struct Metrics {
    let batchSizes: [Int]
    let maximumConcurrentReads: Int
  }

  private var activeReads = 0
  private let barrier = TestBarrier(participantCount: 3)
  private var batchSizes: [Int] = []
  private var maximumConcurrentReads = 0

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
    payloadIdentifiers: [String]
  ) async throws -> [EncryptedProductSyncPayload] {
    batchSizes.append(payloadIdentifiers.count)
    activeReads += 1
    maximumConcurrentReads = max(maximumConcurrentReads, activeReads)
    await barrier.arriveAndWait()
    activeReads -= 1
    return []
  }

  func putEncryptedProductSyncPayloadIfUnchanged(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifier _: String,
    encryptedPayload _: ProductSyncEncryptedPayload,
    expectedUpdatedAt _: Int64?
  ) async throws -> EncryptedProductSyncPayload {
    throw URLError(.unsupportedURL)
  }

  func metrics() -> Metrics {
    Metrics(batchSizes: batchSizes, maximumConcurrentReads: maximumConcurrentReads)
  }
}

private struct ReturningProductSyncRecordTransport: ProductSyncRecordTransport {
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
    payloadIdentifiers: [String]
  ) async throws -> [EncryptedProductSyncPayload] {
    payloadIdentifiers.map {
      EncryptedProductSyncPayload(
        encryptedPayload: ProductSyncEncryptedPayload(
          algorithm: "AES-GCM-256",
          ciphertextBase64: "",
          keyVersion: 1,
          nonceBase64: "",
          schemaVersion: 1,
          tagBase64: ""
        ),
        payloadIdentifier: $0,
        updatedAt: 1
      )
    }
  }

  func putEncryptedProductSyncPayloadIfUnchanged(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifier _: String,
    encryptedPayload _: ProductSyncEncryptedPayload,
    expectedUpdatedAt _: Int64?
  ) async throws -> EncryptedProductSyncPayload {
    throw URLError(.unsupportedURL)
  }
}

private actor CancellingProductSyncCiphertextCache: ProductSyncCiphertextCaching {
  private let cancelOnLoad: Bool
  private var saveCount = 0

  init(cancelOnLoad: Bool = false) {
    self.cancelOnLoad = cancelOnLoad
  }

  func loadFamily(
    productAccountId _: String,
    payloadIdentifierPrefix _: String
  ) async throws -> [EncryptedProductSyncPayload]? {
    nil
  }

  func load(
    productAccountId _: String,
    payloadIdentifier _: String
  ) async throws -> EncryptedProductSyncPayload? {
    if cancelOnLoad { throw CancellationError() }
    return nil
  }

  func remove(productAccountId _: String, payloadIdentifier _: String) async throws {}

  func removeIfUnchanged(
    _: EncryptedProductSyncPayload?,
    productAccountId _: String,
    payloadIdentifier _: String
  ) async throws {}

  func replaceFamily(
    _ payloads: [EncryptedProductSyncPayload],
    productAccountId _: String,
    payloadIdentifierPrefix _: String
  ) async throws {
    _ = payloads
  }

  func save(_ payload: EncryptedProductSyncPayload, productAccountId _: String) async throws {
    _ = payload
    saveCount += 1
    if saveCount == 1 {
      withUnsafeCurrentTask { task in
        task?.cancel()
      }
    }
  }
}

private actor RecordingProductSyncCiphertextCache: ProductSyncCiphertextCaching {
  private var recordedEvents: [String] = []
  private var payloadsByAccount: [String: [String: EncryptedProductSyncPayload]] = [:]

  func loadFamily(
    productAccountId _: String,
    payloadIdentifierPrefix _: String
  ) async throws -> [EncryptedProductSyncPayload]? {
    nil
  }

  func load(
    productAccountId: String,
    payloadIdentifier: String
  ) async throws -> EncryptedProductSyncPayload? {
    payloadsByAccount[productAccountId]?[payloadIdentifier]
  }

  func remove(productAccountId: String, payloadIdentifier: String) async throws {
    payloadsByAccount[productAccountId]?[payloadIdentifier] = nil
    recordedEvents.append("remove")
  }

  func removeIfUnchanged(
    _ payload: EncryptedProductSyncPayload?,
    productAccountId: String,
    payloadIdentifier: String
  ) async throws {
    guard payloadsByAccount[productAccountId]?[payloadIdentifier] == payload else { return }
    payloadsByAccount[productAccountId]?[payloadIdentifier] = nil
    recordedEvents.append("remove")
  }

  func replaceFamily(
    _ payloads: [EncryptedProductSyncPayload],
    productAccountId _: String,
    payloadIdentifierPrefix _: String
  ) async throws {
    _ = payloads
    recordedEvents.append("replaceFamily")
  }

  func save(_ payload: EncryptedProductSyncPayload, productAccountId: String) async throws {
    payloadsByAccount[productAccountId, default: [:]][payload.payloadIdentifier] = payload
    recordedEvents.append("save")
  }

  func resetEvents() {
    recordedEvents = []
  }

  func events() -> [String] {
    recordedEvents
  }
}

private actor CountingProductSyncRecordTransport: ProductSyncRecordTransport {
  private var writes = 0

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
    []
  }

  func putEncryptedProductSyncPayloadIfUnchanged(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifier: String,
    encryptedPayload: ProductSyncEncryptedPayload,
    expectedUpdatedAt _: Int64?
  ) async throws -> EncryptedProductSyncPayload {
    writes += 1
    return EncryptedProductSyncPayload(
      encryptedPayload: encryptedPayload,
      payloadIdentifier: payloadIdentifier,
      updatedAt: Int64(writes)
    )
  }

  func writeCount() -> Int {
    writes
  }
}

private actor SuspendingProductSyncRecordTransport: ProductSyncRecordTransport {
  struct Metrics {
    let maximumByIdentifier: [String: Int]
    let maximumTotal: Int
  }

  private var activeByIdentifier: [String: Int] = [:]
  private let barrier = TestBarrier(participantCount: 2)
  private var barrierArrivals = 0
  private var maximumByIdentifier: [String: Int] = [:]
  private var maximumTotal = 0
  private var payloads: [String: EncryptedProductSyncPayload] = [:]
  private var updatedAt: Int64 = 0

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
    payloadIdentifiers: [String]
  ) async throws -> [EncryptedProductSyncPayload] {
    payloadIdentifiers.compactMap { payloads[$0] }
  }

  func putEncryptedProductSyncPayloadIfUnchanged(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifier: String,
    encryptedPayload: ProductSyncEncryptedPayload,
    expectedUpdatedAt: Int64?
  ) async throws -> EncryptedProductSyncPayload {
    activeByIdentifier[payloadIdentifier, default: 0] += 1
    maximumByIdentifier[payloadIdentifier] = max(
      maximumByIdentifier[payloadIdentifier, default: 0],
      activeByIdentifier[payloadIdentifier, default: 0]
    )
    maximumTotal = max(maximumTotal, activeByIdentifier.values.reduce(0, +))
    barrierArrivals += 1
    if barrierArrivals <= 2 {
      await barrier.arriveAndWait()
    }
    activeByIdentifier[payloadIdentifier, default: 0] -= 1

    if let existing = payloads[payloadIdentifier], existing.updatedAt != expectedUpdatedAt {
      return existing
    }
    updatedAt += 1
    let written = EncryptedProductSyncPayload(
      encryptedPayload: encryptedPayload,
      payloadIdentifier: payloadIdentifier,
      updatedAt: updatedAt
    )
    payloads[payloadIdentifier] = written
    return written
  }

  func metrics() -> Metrics {
    Metrics(maximumByIdentifier: maximumByIdentifier, maximumTotal: maximumTotal)
  }
}

private struct FixedProductSyncRecordTransport: ProductSyncRecordTransport {
  let payloads: [EncryptedProductSyncPayload]

  func listEncryptedProductSyncPayloads(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifierPrefix _: String,
    cursor _: String?,
    limit _: Int
  ) async throws -> EncryptedProductSyncPayloadPage {
    EncryptedProductSyncPayloadPage(continueCursor: "", isDone: true, page: payloads)
  }

  func getEncryptedProductSyncPayloads(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifiers: [String]
  ) async throws -> [EncryptedProductSyncPayload] {
    payloads.filter { payloadIdentifiers.contains($0.payloadIdentifier) }
  }

  func putEncryptedProductSyncPayloadIfUnchanged(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifier _: String,
    encryptedPayload _: ProductSyncEncryptedPayload,
    expectedUpdatedAt _: Int64?
  ) async throws -> EncryptedProductSyncPayload {
    throw URLError(.unsupportedURL)
  }
}

private struct PaginatedTestTransport: ProductSyncRecordTransport {
  enum CursorMode: CaseIterable {
    case missing
    case repeated
    case unbounded
  }

  let cursorMode: CursorMode

  func listEncryptedProductSyncPayloads(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifierPrefix _: String,
    cursor: String?,
    limit _: Int
  ) async throws -> EncryptedProductSyncPayloadPage {
    let continueCursor: String
    switch cursorMode {
    case .missing:
      continueCursor = ""
    case .repeated:
      continueCursor = "same"
    case .unbounded:
      continueCursor = String((Int(cursor ?? "0") ?? 0) + 1)
    }
    return EncryptedProductSyncPayloadPage(
      continueCursor: continueCursor,
      isDone: false,
      page: []
    )
  }

  func getEncryptedProductSyncPayloads(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifiers _: [String]
  ) async throws -> [EncryptedProductSyncPayload] {
    []
  }

  func putEncryptedProductSyncPayloadIfUnchanged(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifier _: String,
    encryptedPayload _: ProductSyncEncryptedPayload,
    expectedUpdatedAt _: Int64?
  ) async throws -> EncryptedProductSyncPayload {
    throw URLError(.unsupportedURL)
  }
}

private actor LockHoldingProductSyncRecordTransport: ProductSyncRecordTransport {
  private var reads = 0
  private let writeRendezvous = TestRendezvous()

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
    reads += 1
    return []
  }

  func putEncryptedProductSyncPayloadIfUnchanged(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifier: String,
    encryptedPayload: ProductSyncEncryptedPayload,
    expectedUpdatedAt _: Int64?
  ) async throws -> EncryptedProductSyncPayload {
    await writeRendezvous.hold()
    return EncryptedProductSyncPayload(
      encryptedPayload: encryptedPayload,
      payloadIdentifier: payloadIdentifier,
      updatedAt: 1
    )
  }

  func waitUntilWriteHeld() async {
    await writeRendezvous.waitUntilHeld()
  }

  func releaseWrite() async {
    await writeRendezvous.release()
  }

  func readCount() -> Int {
    reads
  }
}

private struct FailingProductSyncRecordTransport: ProductSyncRecordTransport {
  func listEncryptedProductSyncPayloads(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifierPrefix _: String,
    cursor _: String?,
    limit _: Int
  ) async throws -> EncryptedProductSyncPayloadPage {
    throw URLError(.notConnectedToInternet)
  }

  func getEncryptedProductSyncPayloads(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifiers _: [String]
  ) async throws -> [EncryptedProductSyncPayload] {
    throw URLError(.notConnectedToInternet)
  }

  func putEncryptedProductSyncPayloadIfUnchanged(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifier _: String,
    encryptedPayload _: ProductSyncEncryptedPayload,
    expectedUpdatedAt _: Int64?
  ) async throws -> EncryptedProductSyncPayload {
    throw URLError(.notConnectedToInternet)
  }
}

private actor ConflictOnceProductSyncRecordTransport: ProductSyncRecordTransport {
  private let authoritativePayload: EncryptedProductSyncPayload
  private var writes = 0

  init(authoritativePayload: EncryptedProductSyncPayload) {
    self.authoritativePayload = authoritativePayload
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
    []
  }

  func putEncryptedProductSyncPayloadIfUnchanged(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifier _: String,
    encryptedPayload _: ProductSyncEncryptedPayload,
    expectedUpdatedAt _: Int64?
  ) async throws -> EncryptedProductSyncPayload {
    writes += 1
    return authoritativePayload
  }

  func writeCount() -> Int {
    writes
  }
}
