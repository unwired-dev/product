import XCTest

@testable import unwired_mail

// swiftlint:disable file_length type_body_length
@MainActor
final class ProductAccountSessionTests: XCTestCase {
  private var store = InMemoryProductAccountSessionStore()
  private var keyMaterialStore = InMemoryProductSyncKeyMaterialStore()
  private var pushUnregisterer = RecordingDevicePushUnregisterer()

  override func setUp() {
    store = InMemoryProductAccountSessionStore()
    keyMaterialStore = InMemoryProductSyncKeyMaterialStore()
    pushUnregisterer = RecordingDevicePushUnregisterer()
  }

  func testSignInStoresSessionAndMovesToSignedInState() async {
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: "apple-user-001",
          identityToken: "e30.eyJleHAiOjEwMDB9.signature"
        )
      ),
      devicePushUnregistrationService: pushUnregisterer,
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
    XCTAssertEqual(
      snapshot.identityTokenExpiresAt,
      Date(timeIntervalSince1970: 1_000)
    )
    XCTAssertEqual(try store.load(), snapshot)
    XCTAssertNotNil(try keyMaterialStore.load(productAccountId: snapshot.productAccountId))
  }

  func testAppleIdentityTokenExpirationRejectsUnverifiableClaims() {
    let invalidTokens = [
      "not-an-identity-token",
      "e30.!.signature",
      "e30.e30.signature",
      "e30.eyJleHAiOiJzb29uIn0.signature",
    ]

    for token in invalidTokens {
      XCTAssertNil(AppleIdentityToken.expirationDate(from: token))
    }
  }

  func testAppleIdentityTokenExpirationReadsNumericClaim() {
    XCTAssertEqual(
      AppleIdentityToken.expirationDate(from: "e30.eyJleHAiOjEwMDB9.signature"),
      Date(timeIntervalSince1970: 1_000)
    )
  }

  func testRestoreSessionReturnsStoredCredentialWhenAppleAuthorizationIsCurrent() async throws {
    let snapshot = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "token-001",
      productAccountId: "product-account-001",
      trustedDeviceId: "trusted-device-001"
    )
    let service = SignInWithAppleService(
      authorizationStateChecker: StubAuthorizationChecker(
        state: .authorized
      )
    )

    let credential = try await service.restoreSession(snapshot: snapshot)

    XCTAssertEqual(
      credential,
      AppleSignInCredential(
        appleUserIdentifier: snapshot.appleUserIdentifier,
        identityToken: snapshot.identityToken
      )
    )
  }

  func testRestoreSessionRejectsRevokedAndMissingAppleAuthorization() async {
    for state in [
      ProductAccountAuthorizationState.revoked,
      ProductAccountAuthorizationState.unauthorized,
    ] {
      let service = SignInWithAppleService(
        authorizationStateChecker: StubAuthorizationChecker(state: state)
      )

      do {
        _ = try await service.restoreSession(snapshot: Self.restorableSnapshot)
        XCTFail("Expected \(state) authorization to be rejected")
      } catch {
        XCTAssertEqual(error as? AppleSignInError, .notAuthorized)
      }
    }
  }

  func testRestoreSessionReportsUnavailableAppleCredentialState() async {
    let service = SignInWithAppleService(
      authorizationStateChecker: StubAuthorizationChecker(
        state: .unavailable
      )
    )

    do {
      _ = try await service.restoreSession(snapshot: Self.restorableSnapshot)
      XCTFail("Expected unavailable authorization state to fail restoration")
    } catch {
      XCTAssertEqual(error as? AppleSignInError, .credentialUnavailable)
    }
  }

  private static let restorableSnapshot = ProductAccountSessionSnapshot(
    appleUserIdentifier: "apple-user-001",
    identityToken: "token-001",
    productAccountId: "product-account-001",
    trustedDeviceId: "trusted-device-001"
  )

  func testSignOutClearsStoredSession() async {
    let gmailConnectionService = RecordingGmailProviderConnecting()
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: "apple-user-001",
          identityToken: "token-001"
        )
      ),
      devicePushUnregistrationService: pushUnregisterer,
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: store,
      mailboxConnectionService: GmailMailboxConnectionAdapter(
        connectionService: gmailConnectionService
      ),
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.signInWithApple()
    await session.signOut()

    XCTAssertEqual(session.state, .signedOut)
    XCTAssertNil(try store.load())
    XCTAssertEqual(
      gmailConnectionService.clearedSession?.productAccountId,
      ProductAccountConnectResponse.preview.productAccountId
    )
    XCTAssertEqual(
      pushUnregisterer.sessions.first?.productAccountId,
      ProductAccountConnectResponse.preview.productAccountId
    )
  }

  func testSignOutPreservesSessionSavedByConcurrentSignIn() async throws {
    let oldSnapshot = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "old-token",
      productAccountId: ProductAccountConnectResponse.preview.productAccountId,
      trustedDeviceId: ProductAccountConnectResponse.preview.trustedDeviceId
    )
    try store.save(oldSnapshot)
    let unregistrationGate = SignOutUnregistrationGate()
    let gmailConnectionService = RecordingGmailProviderConnecting()
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: "apple-user-001",
          identityToken: "new-token"
        )
      ),
      devicePushUnregistrationService: SuspendingDevicePushUnregisterer(
        gate: unregistrationGate
      ),
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: store,
      mailboxConnectionService: gmailConnectionService,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    let signOutTask = Task {
      await session.signOut()
    }
    await unregistrationGate.waitUntilStarted()
    await session.signInWithApple()
    guard case .signedIn(let newSnapshot) = session.state else {
      return XCTFail("Expected concurrent sign-in to complete")
    }
    await unregistrationGate.release()
    await signOutTask.value

    XCTAssertEqual(session.state, .signedIn(newSnapshot))
    XCTAssertEqual(try store.load(), newSnapshot)
    XCTAssertEqual(gmailConnectionService.clearedSessions, [])
  }

  func testSignOutPreservesSessionSavedDuringGmailCleanup() async throws {
    let oldSnapshot = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "old-token",
      productAccountId: ProductAccountConnectResponse.preview.productAccountId,
      trustedDeviceId: ProductAccountConnectResponse.preview.trustedDeviceId
    )
    try store.save(oldSnapshot)
    let gmailCleanupGate = SignOutUnregistrationGate()
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: "apple-user-001",
          identityToken: "new-token"
        )
      ),
      devicePushUnregistrationService: pushUnregisterer,
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: store,
      mailboxConnectionService: SuspendingGmailProviderConnecting(
        gate: gmailCleanupGate
      ),
      productSyncKeyMaterialStore: keyMaterialStore
    )

    let signOutTask = Task {
      await session.signOut()
    }
    await gmailCleanupGate.waitUntilStarted()
    await session.signInWithApple()
    guard case .signedIn(let newSnapshot) = session.state else {
      return XCTFail("Expected concurrent sign-in to complete")
    }
    await gmailCleanupGate.release()
    await signOutTask.value

    XCTAssertEqual(session.state, .signedIn(newSnapshot))
    XCTAssertEqual(try store.load(), newSnapshot)
  }

  func testSignOutPreservesStoredSessionWhenGmailCleanupFails() async throws {
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
      devicePushUnregistrationService: pushUnregisterer,
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: store,
      mailboxConnectionService: gmailConnectionService,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.signOut()

    XCTAssertEqual(
      session.state, .failed(ProductAccountSessionTestError.gmailCleanupFailed.localizedDescription)
    )
    XCTAssertEqual(try store.load(), snapshot)
    XCTAssertEqual(gmailConnectionService.clearedSessions, [snapshot])
  }

  func testSignOutPreservesStoredSessionWhenBodyCacheCleanupFails() async throws {
    let snapshot = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "token-001",
      productAccountId: "productAccountFixtureId",
      trustedDeviceId: "trustedDeviceFixtureId"
    )
    try store.save(snapshot)
    let gmailConnectionService = GmailProviderConnectionService(
      bodyReader: FailingGmailMessageReader()
    )
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: "apple-user-001",
          identityToken: "token-001"
        )
      ),
      devicePushUnregistrationService: pushUnregisterer,
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: store,
      mailboxConnectionService: GmailMailboxConnectionAdapter(
        connectionService: gmailConnectionService
      ),
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.signOut()

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

    await session.signOut()

    XCTAssertEqual(session.state, .signedOut)
    XCTAssertTrue(sessionStore.didClear)
  }

  func testSignedInSignOutDoesNotRequireSessionReload() async {
    let sessionStore = ControllableProductAccountSessionStore()
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: "apple-user-001",
          identityToken: "token-001"
        )
      ),
      devicePushUnregistrationService: pushUnregisterer,
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: sessionStore,
      productSyncKeyMaterialStore: keyMaterialStore
    )
    await session.signInWithApple()
    sessionStore.loadError = ProductAccountSessionTestError.sessionLoadFailed

    await session.signOut()

    XCTAssertEqual(session.state, .signedOut)
    XCTAssertTrue(sessionStore.didClear)
  }

  func testSignOutClearsSessionWhenExpiredIdentityPreventsPushUnregistration() async throws {
    let snapshot = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "token-001",
      productAccountId: "productAccountFixtureId",
      trustedDeviceId: "trustedDeviceFixtureId"
    )
    try store.save(snapshot)
    pushUnregisterer.error = ConvexClientError.convexFailure(
      status: "error",
      message: "Authentication required"
    )
    let gmailConnectionService = RecordingGmailProviderConnecting()
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: "apple-user-001",
          identityToken: "token-001"
        )
      ),
      devicePushUnregistrationService: pushUnregisterer,
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: store,
      mailboxConnectionService: gmailConnectionService,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.signOut()

    XCTAssertEqual(session.state, .signedOut)
    XCTAssertNil(try store.load())
    XCTAssertEqual(gmailConnectionService.clearedSessions, [snapshot])
  }

  func testSignInCompletesAccountSwitchWhenPushUnregistrationFails() async throws {
    let oldSnapshot = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "old-token",
      productAccountId: "oldProductAccountId",
      trustedDeviceId: "oldTrustedDeviceId"
    )
    try store.save(oldSnapshot)
    pushUnregisterer.error = ProductAccountSessionTestError.pushUnregistrationFailed
    let gmailConnectionService = RecordingGmailProviderConnecting()
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: "apple-user-002",
          identityToken: "token-002"
        )
      ),
      devicePushUnregistrationService: pushUnregisterer,
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: store,
      mailboxConnectionService: gmailConnectionService,
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
    XCTAssertEqual(pushUnregisterer.sessions, [oldSnapshot])
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
      devicePushUnregistrationService: pushUnregisterer,
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: sessionStore,
      mailboxConnectionService: gmailConnectionService,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.signInWithApple()

    guard case .failed = session.state else {
      return XCTFail("Expected failed state")
    }
    XCTAssertEqual(try sessionStore.load(), oldSnapshot)
    XCTAssertEqual(gmailConnectionService.clearedSessions, [])
    XCTAssertEqual(pushUnregisterer.sessions, [])
  }

  func testSignInRestoresPreviousSessionWhenBodyCacheCleanupFails() async throws {
    let oldSnapshot = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "old-token",
      productAccountId: "oldProductAccountId",
      trustedDeviceId: "oldTrustedDeviceId"
    )
    try store.save(oldSnapshot)
    let gmailConnectionService = RecordingGmailProviderConnecting()
    gmailConnectionService.clearError = ProductAccountSessionTestError.gmailCleanupFailed
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: "apple-user-002",
          identityToken: "token-002"
        )
      ),
      devicePushUnregistrationService: pushUnregisterer,
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: store,
      mailboxConnectionService: gmailConnectionService,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.signInWithApple()

    guard case .failed = session.state else {
      return XCTFail("Expected failed state")
    }
    XCTAssertEqual(try store.load(), oldSnapshot)
    XCTAssertEqual(gmailConnectionService.clearedSessions, [oldSnapshot])
    XCTAssertEqual(pushUnregisterer.sessions, [])
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
      devicePushUnregistrationService: pushUnregisterer,
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: store,
      mailboxConnectionService: gmailConnectionService,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.bootstrap()

    XCTAssertEqual(session.state, .signedOut)
    XCTAssertNil(try store.load())
    XCTAssertEqual(gmailConnectionService.clearedSession, snapshot)
    XCTAssertEqual(pushUnregisterer.sessions, [snapshot])
  }

  func testBootstrapPreservesStoredSessionWhenRevokedBodyCacheCleanupFails() async throws {
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
      appleSignInService: RevokedAppleSignInService(),
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: store,
      mailboxConnectionService: gmailConnectionService,
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
      devicePushUnregistrationService: pushUnregisterer,
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: store,
      mailboxConnectionService: gmailConnectionService,
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
    XCTAssertEqual(pushUnregisterer.sessions, [oldSnapshot])
  }

  func testBootstrapRestoresPreviousSessionBeforePushCleanupWhenGmailCleanupFails() async throws {
    let oldSnapshot = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "old-token",
      productAccountId: "oldProductAccountId",
      trustedDeviceId: "oldTrustedDeviceId"
    )
    try store.save(oldSnapshot)
    let gmailConnectionService = RecordingGmailProviderConnecting()
    gmailConnectionService.clearError = ProductAccountSessionTestError.gmailCleanupFailed
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: "apple-user-001",
          identityToken: "token-001"
        )
      ),
      devicePushUnregistrationService: pushUnregisterer,
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: store,
      mailboxConnectionService: gmailConnectionService,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.bootstrap()

    guard case .failed = session.state else {
      return XCTFail("Expected failed state")
    }
    XCTAssertEqual(try store.load(), oldSnapshot)
    XCTAssertEqual(gmailConnectionService.clearedSessions, [oldSnapshot])
    XCTAssertEqual(pushUnregisterer.sessions, [])
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

private struct StubAuthorizationChecker:
  ProductAccountAuthorizationStateChecking
{
  let state: ProductAccountAuthorizationState

  func authorizationState(
    forAppleUserIdentifier _: String
  ) async -> ProductAccountAuthorizationState {
    state
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
  case pushUnregistrationFailed
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

private final class RecordingGmailProviderConnecting:
  GmailProviderConnecting, MailboxConnectionClearing
{
  var clearedSession: ProductAccountSessionSnapshot?
  var clearedSessions: [ProductAccountSessionSnapshot] = []
  var clearError: Error?

  func clearLocalConnection(
    session: ProductAccountSessionSnapshot
  ) async throws {
    clearedSession = session
    clearedSessions.append(session)
    if let clearError {
      throw clearError
    }
  }

  func clearLocalConnection(
    _: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) async throws {}

  func clearLocalConnection(
    _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws {}

  func completeConnection(
    verifiedAccount: VerifiedGmailAccount,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailProviderConnectionStatus {
    _ = verifiedAccount
    _ = session
    throw ConvexClientError.missingConvexURL
  }

  func loadConnections(
    session: ProductAccountSessionSnapshot
  ) async throws -> [GmailProviderConnectionStatus] {
    _ = session
    return []
  }

  func loadStoredConnections(
    session _: ProductAccountSessionSnapshot
  ) async throws -> [GmailProviderConnectionStatus] {
    []
  }

  func hasLocalAuthorization(
    _: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) throws -> Bool { true }

  func bindAuthorizationGeneration(
    _ authorizationGeneration: Int,
    to connection: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) throws -> GmailProviderConnectionStatus {
    connection.withAuthorizationGeneration(authorizationGeneration)
  }
}

private final class RecordingDevicePushUnregisterer: DevicePushUnregistering {
  var error: Error?
  var sessions: [ProductAccountSessionSnapshot] = []

  func unregister(session: ProductAccountSessionSnapshot) async throws {
    sessions.append(session)
    if let error {
      throw error
    }
  }
}

private actor SignOutUnregistrationGate {
  private var hasStarted = false
  private var releaseContinuation: CheckedContinuation<Void, Never>?
  private var startContinuations: [CheckedContinuation<Void, Never>] = []

  func waitForRelease() async {
    hasStarted = true
    let continuations = startContinuations
    startContinuations.removeAll()
    for continuation in continuations {
      continuation.resume()
    }
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
  }

  func waitUntilStarted() async {
    guard !hasStarted else { return }
    await withCheckedContinuation { continuation in
      startContinuations.append(continuation)
    }
  }

  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}

private struct SuspendingDevicePushUnregisterer: DevicePushUnregistering {
  let gate: SignOutUnregistrationGate

  func unregister(session _: ProductAccountSessionSnapshot) async throws {
    await gate.waitForRelease()
  }
}

private struct SuspendingGmailProviderConnecting:
  GmailProviderConnecting, MailboxConnectionClearing
{
  let gate: SignOutUnregistrationGate

  func clearLocalConnection(session _: ProductAccountSessionSnapshot) async throws {
    await gate.waitForRelease()
  }

  func clearLocalConnection(
    _: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) async throws {}

  func clearLocalConnection(
    _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws {}

  func completeConnection(
    verifiedAccount _: VerifiedGmailAccount,
    session _: ProductAccountSessionSnapshot
  ) async throws -> GmailProviderConnectionStatus {
    throw ConvexClientError.missingConvexURL
  }

  func loadConnections(
    session _: ProductAccountSessionSnapshot
  ) async throws -> [GmailProviderConnectionStatus] {
    []
  }

  func loadStoredConnections(
    session _: ProductAccountSessionSnapshot
  ) async throws -> [GmailProviderConnectionStatus] {
    []
  }

  func hasLocalAuthorization(
    _: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) throws -> Bool { true }

  func bindAuthorizationGeneration(
    _ authorizationGeneration: Int,
    to connection: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) throws -> GmailProviderConnectionStatus {
    connection.withAuthorizationGeneration(authorizationGeneration)
  }
}

private struct FailingGmailMessageReader: GmailMessageReading {
  func clearCachedMessageBodies(session _: ProductAccountSessionSnapshot) throws {
    throw ProductAccountSessionTestError.gmailCleanupFailed
  }

  func clearCachedMessageBodies(
    connection _: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) throws {
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
