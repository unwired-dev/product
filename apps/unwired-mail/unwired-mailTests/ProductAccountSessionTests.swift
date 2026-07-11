import XCTest

@testable import unwired_mail

// swiftlint:disable file_length type_body_length
@MainActor
final class ProductAccountSessionTests: XCTestCase {
  private var store = InMemoryProductAccountSessionStore()
  private var keyMaterialStore = InMemoryProductSyncKeyMaterialStore()

  override func setUp() {
    store = InMemoryProductAccountSessionStore()
    keyMaterialStore = InMemoryProductSyncKeyMaterialStore()
  }

  func testSignInStoresSessionAndMovesToSignedInState() async {
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: "apple-user-001",
          identityToken: "token-001"
        )
      ),
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.signInWithApple()

    guard case .signedIn(let snapshot) = session.state else {
      return XCTFail("Expected signed-in state")
    }

    XCTAssertEqual(
      snapshot.productAccountId,
      ProductAccountConnectResponse.preview.productAccountId
    )
    XCTAssertEqual(try store.load(), snapshot)
    XCTAssertNotNil(try keyMaterialStore.load(productAccountId: snapshot.productAccountId))
  }

  func testSignOutClearsStoredSession() async {
    let gmailConnectionService = RecordingGmailProviderConnecting()
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: "apple-user-001",
          identityToken: "token-001"
        )
      ),
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: store,
      gmailProviderConnectionService: gmailConnectionService,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.signInWithApple()
    session.signOut()

    XCTAssertEqual(session.state, .signedOut)
    XCTAssertNil(try store.load())
    XCTAssertEqual(
      gmailConnectionService.clearedSession?.productAccountId,
      ProductAccountConnectResponse.preview.productAccountId
    )
  }

  func testSignOutClearsStoredSessionWhenGmailCleanupFails() async throws {
    let snapshot = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "token-001",
      productAccountId: "productAccountFixtureId",
      trustedDeviceId: "trustedDeviceFixtureId"
    )
    try store.save(snapshot)
    let gmailConnectionService = RecordingGmailProviderConnecting()
    gmailConnectionService.clearError = ProductAccountSessionTestError.gmailCleanupFailed
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: "apple-user-001",
          identityToken: "token-001"
        )
      ),
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: store,
      gmailProviderConnectionService: gmailConnectionService,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    session.signOut()

    XCTAssertEqual(session.state, .signedOut)
    XCTAssertNil(try store.load())
    XCTAssertEqual(gmailConnectionService.clearedSessions, [snapshot])
  }

  func testSignOutKeepsSessionWhenBodyCacheCleanupFails() async throws {
    let snapshot = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "token-001",
      productAccountId: "productAccountFixtureId",
      trustedDeviceId: "trustedDeviceFixtureId"
    )
    try store.save(snapshot)
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: "apple-user-001",
          identityToken: "token-001"
        )
      ),
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: store,
      gmailMessageBodyReader: FailingGmailMessageReader(),
      productSyncKeyMaterialStore: keyMaterialStore
    )

    session.signOut()

    XCTAssertEqual(
      session.state, .failed(ProductAccountSessionTestError.gmailCleanupFailed.localizedDescription)
    )
    XCTAssertEqual(try store.load(), snapshot)
  }

  func testSignOutClearsStoredSessionWhenSessionReloadFails() async {
    let sessionStore = ControllableProductAccountSessionStore()
    sessionStore.loadError = ProductAccountSessionTestError.sessionLoadFailed
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: "apple-user-001",
          identityToken: "token-001"
        )
      ),
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: sessionStore,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    session.signOut()

    XCTAssertEqual(session.state, .signedOut)
    XCTAssertTrue(sessionStore.didClear)
  }

  func testSignInClearsPreviousGmailTokensWhenProductAccountChanges() async throws {
    let oldSnapshot = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "old-token",
      productAccountId: "oldProductAccountId",
      trustedDeviceId: "oldTrustedDeviceId"
    )
    try store.save(oldSnapshot)
    let gmailConnectionService = RecordingGmailProviderConnecting()
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: "apple-user-002",
          identityToken: "token-002"
        )
      ),
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: store,
      gmailProviderConnectionService: gmailConnectionService,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.signInWithApple()

    guard case .signedIn(let snapshot) = session.state else {
      return XCTFail("Expected signed-in state")
    }
    XCTAssertEqual(
      snapshot.productAccountId, ProductAccountConnectResponse.preview.productAccountId)
    XCTAssertEqual(try store.load(), snapshot)
    XCTAssertEqual(gmailConnectionService.clearedSessions, [oldSnapshot])
  }

  func testSignInKeepsPreviousGmailTokensWhenNewSessionSaveFails() async throws {
    let oldSnapshot = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "old-token",
      productAccountId: "oldProductAccountId",
      trustedDeviceId: "oldTrustedDeviceId"
    )
    let sessionStore = ControllableProductAccountSessionStore(snapshot: oldSnapshot)
    sessionStore.saveError = ProductAccountSessionTestError.sessionSaveFailed
    let gmailConnectionService = RecordingGmailProviderConnecting()
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: "apple-user-002",
          identityToken: "token-002"
        )
      ),
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: sessionStore,
      gmailProviderConnectionService: gmailConnectionService,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.signInWithApple()

    guard case .failed = session.state else {
      return XCTFail("Expected failed state")
    }
    XCTAssertEqual(try sessionStore.load(), oldSnapshot)
    XCTAssertEqual(gmailConnectionService.clearedSessions, [])
  }

  func testSignInRestoresPreviousSessionWhenBodyCacheCleanupFails() async throws {
    let oldSnapshot = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "old-token",
      productAccountId: "oldProductAccountId",
      trustedDeviceId: "oldTrustedDeviceId"
    )
    try store.save(oldSnapshot)
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: "apple-user-002",
          identityToken: "token-002"
        )
      ),
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: store,
      gmailMessageBodyReader: FailingGmailMessageReader(),
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.signInWithApple()

    guard case .failed = session.state else {
      return XCTFail("Expected failed state")
    }
    XCTAssertEqual(try store.load(), oldSnapshot)
  }

  func testBootstrapPreservesSessionOnTransientBackendFailure() async throws {
    let snapshot = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "token-001",
      productAccountId: "productAccountFixtureId",
      trustedDeviceId: "trustedDeviceFixtureId"
    )
    try store.save(snapshot)

    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: "apple-user-001",
          identityToken: "token-001"
        )
      ),
      productAccountService: FailingProductAccountService(),
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.bootstrap()

    guard case .failed = session.state else {
      return XCTFail("Expected failed state")
    }
    XCTAssertEqual(try store.load(), snapshot)
  }

  func testBootstrapClearsGmailTokensWhenAppleSessionIsRevoked() async throws {
    let snapshot = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "token-001",
      productAccountId: "productAccountFixtureId",
      trustedDeviceId: "trustedDeviceFixtureId"
    )
    try store.save(snapshot)
    let gmailConnectionService = RecordingGmailProviderConnecting()
    let session = ProductAccountSession(
      appleSignInService: RevokedAppleSignInService(),
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: store,
      gmailProviderConnectionService: gmailConnectionService,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.bootstrap()

    XCTAssertEqual(session.state, .signedOut)
    XCTAssertNil(try store.load())
    XCTAssertEqual(gmailConnectionService.clearedSession, snapshot)
  }

  func testBootstrapKeepsSessionWhenRevokedBodyCacheCleanupFails() async throws {
    let snapshot = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "token-001",
      productAccountId: "productAccountFixtureId",
      trustedDeviceId: "trustedDeviceFixtureId"
    )
    try store.save(snapshot)
    let session = ProductAccountSession(
      appleSignInService: RevokedAppleSignInService(),
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: store,
      gmailMessageBodyReader: FailingGmailMessageReader(),
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.bootstrap()

    guard case .failed = session.state else {
      return XCTFail("Expected failed state")
    }
    XCTAssertEqual(try store.load(), snapshot)
  }

  func testBootstrapClearsPreviousGmailTokensWhenProductAccountChanges() async throws {
    let oldSnapshot = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "old-token",
      productAccountId: "oldProductAccountId",
      trustedDeviceId: "oldTrustedDeviceId"
    )
    try store.save(oldSnapshot)
    let gmailConnectionService = RecordingGmailProviderConnecting()
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: "apple-user-001",
          identityToken: "token-001"
        )
      ),
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: store,
      gmailProviderConnectionService: gmailConnectionService,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.bootstrap()

    guard case .signedIn(let snapshot) = session.state else {
      return XCTFail("Expected signed-in state")
    }
    XCTAssertEqual(
      snapshot.productAccountId, ProductAccountConnectResponse.preview.productAccountId)
    XCTAssertEqual(try store.load(), snapshot)
    XCTAssertEqual(gmailConnectionService.clearedSessions, [oldSnapshot])
  }

  func testExistingProductAccountWithoutLocalSyncMaterialRequiresRecovery() async {
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: "apple-user-001",
          identityToken: "token-001"
        )
      ),
      productAccountService: PreviewProductAccountService(response: .resumed),
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.signInWithApple()

    guard case .failed(let message) = session.state else {
      return XCTFail("Expected failed state")
    }
    XCTAssertEqual(
      message,
      ProductSyncKeyMaterialStoreError.recoveryRequired.localizedDescription
    )
    XCTAssertNil(
      try keyMaterialStore.load(
        productAccountId: ProductAccountConnectResponse.resumed.productAccountId
      )
    )
  }

  func testSameDeviceIncompleteInitialBootstrapCreatesMissingMaterial() async {
    let response = ProductAccountConnectResponse(
      accountCreated: false,
      deviceRegistered: false,
      productSyncMaterialInitialized: false,
      productAccountId: "productAccountFixtureId",
      trustedDeviceId: "trustedDeviceFixtureId"
    )
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: "apple-user-001",
          identityToken: "token-001"
        )
      ),
      productAccountService: PreviewProductAccountService(response: response),
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.signInWithApple()

    guard case .signedIn(let snapshot) = session.state else {
      return XCTFail("Expected signed-in state")
    }
    XCTAssertEqual(snapshot.productAccountId, response.productAccountId)
    XCTAssertNotNil(try keyMaterialStore.load(productAccountId: response.productAccountId))
  }

  func testReturningRegisteredDeviceWithInitializedSyncMaterialRequiresRecovery() async {
    let response = ProductAccountConnectResponse(
      accountCreated: false,
      deviceRegistered: false,
      productSyncMaterialInitialized: true,
      productAccountId: "productAccountFixtureId",
      trustedDeviceId: "trustedDeviceFixtureId"
    )
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: "apple-user-001",
          identityToken: "token-001"
        )
      ),
      productAccountService: PreviewProductAccountService(response: response),
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.signInWithApple()

    guard case .failed(let message) = session.state else {
      return XCTFail("Expected failed state")
    }
    XCTAssertEqual(
      message,
      ProductSyncKeyMaterialStoreError.recoveryRequired.localizedDescription
    )
    XCTAssertNil(try keyMaterialStore.load(productAccountId: response.productAccountId))
  }

  func testNewDeviceForUninitializedAccountRequiresRecovery() async {
    let response = ProductAccountConnectResponse(
      accountCreated: false,
      deviceRegistered: true,
      productSyncMaterialInitialized: false,
      productAccountId: "productAccountFixtureId",
      trustedDeviceId: "trustedDeviceFixtureId"
    )
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: "apple-user-001",
          identityToken: "token-001"
        )
      ),
      productAccountService: PreviewProductAccountService(response: response),
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.signInWithApple()

    guard case .failed(let message) = session.state else {
      return XCTFail("Expected failed state")
    }
    XCTAssertEqual(
      message,
      ProductSyncKeyMaterialStoreError.recoveryRequired.localizedDescription
    )
    XCTAssertNil(try keyMaterialStore.load(productAccountId: response.productAccountId))
  }
}

private struct FailingProductAccountService: ProductAccountConnecting {
  func connect(identityToken: String) async throws -> ProductAccountConnectResponse {
    _ = identityToken
    throw ConvexClientError.missingConvexURL
  }

  func markProductSyncMaterialInitialized(
    identityToken: String,
    trustedDeviceId: String
  ) async throws -> ProductSyncMaterialInitializedResponse {
    _ = identityToken
    _ = trustedDeviceId
    throw ConvexClientError.missingConvexURL
  }
}

private struct RevokedAppleSignInService: AppleSignInPerforming {
  func signIn() async throws -> AppleSignInCredential {
    throw AppleSignInError.notAuthorized
  }

  func restoreSession(
    snapshot: ProductAccountSessionSnapshot
  ) async throws -> AppleSignInCredential {
    _ = snapshot
    throw AppleSignInError.notAuthorized
  }
}

private enum ProductAccountSessionTestError: Error {
  case gmailCleanupFailed
  case sessionLoadFailed
  case sessionSaveFailed
}

private final class ControllableProductAccountSessionStore: ProductAccountSessionPersisting {
  var didClear = false
  var loadError: Error?
  var saveError: Error?

  private var snapshot: ProductAccountSessionSnapshot?

  init(snapshot: ProductAccountSessionSnapshot? = nil) {
    self.snapshot = snapshot
  }

  func load() throws -> ProductAccountSessionSnapshot? {
    if let loadError {
      throw loadError
    }

    return snapshot
  }

  func save(_ snapshot: ProductAccountSessionSnapshot) throws {
    if let saveError {
      throw saveError
    }

    self.snapshot = snapshot
  }

  func clear() throws {
    didClear = true
    snapshot = nil
  }
}

private final class RecordingGmailProviderConnecting: GmailProviderConnecting {
  var clearedSession: ProductAccountSessionSnapshot?
  var clearedSessions: [ProductAccountSessionSnapshot] = []
  var clearError: Error?

  func clearLocalConnection(
    session: ProductAccountSessionSnapshot
  ) throws {
    clearedSession = session
    clearedSessions.append(session)
    if let clearError {
      throw clearError
    }
  }

  func completeConnection(
    verifiedAccount: VerifiedGmailAccount,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailProviderConnectionStatus {
    _ = verifiedAccount
    _ = session
    throw ConvexClientError.missingConvexURL
  }

  func loadConnection(
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailProviderConnectionStatus? {
    _ = session
    return nil
  }
}

private struct FailingGmailMessageReader: GmailMessageReading {
  func clearCachedMessageBodies(session _: ProductAccountSessionSnapshot) throws {
    throw ProductAccountSessionTestError.gmailCleanupFailed
  }

  func loadMessageBody(
    message _: GmailMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) async throws -> GmailMessageBody {
    throw ProductAccountSessionTestError.gmailCleanupFailed
  }

  func removeCachedMessageBody(
    message _: GmailMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) throws {
    throw ProductAccountSessionTestError.gmailCleanupFailed
  }
}
