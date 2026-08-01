import AuthenticationServices
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

  private func waitForRecoveryOperationWaiter(productAccountId: String) async {
    let queued = expectation(description: "recovery operation queued")
    let observer = Task {
      for _ in 0..<1_000 {
        if await productAccountRecoveryOperationGate.pendingWaiterCount(
          productAccountId: productAccountId
        ) > 0 {
          queued.fulfill()
          return
        }
        await Task.yield()
      }
    }
    await fulfillment(of: [queued], timeout: 1)
    observer.cancel()
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

  func testSignInCompletesInterruptedSignOutBeforeSavingSession() async throws {
    let oldSnapshot = Self.restorableSnapshot
    try store.save(oldSnapshot)
    try store.savePendingSignOutProductAccountId(oldSnapshot.productAccountId)
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: oldSnapshot.productAccountId,
      allowCreation: true
    )
    let session = ProductAccountSession(
      appleSignInService: SequencedAppleSignInService(
        credentials: [
          AppleSignInCredential(
            appleUserIdentifier: oldSnapshot.appleUserIdentifier,
            identityToken: "refreshed-old-token"
          ),
          AppleSignInCredential(
            appleUserIdentifier: "apple-user-002",
            identityToken: "token-002"
          ),
        ]
      ),
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.signInWithApple()

    guard case .signedIn(let snapshot) = session.state else {
      return XCTFail("Expected signed-in state")
    }
    XCTAssertEqual(snapshot.appleUserIdentifier, "apple-user-002")
    XCTAssertEqual(try store.load(), snapshot)
    XCTAssertNil(try store.loadPendingSignOutProductAccountId())
    XCTAssertNil(
      try keyMaterialStore.load(productAccountId: oldSnapshot.productAccountId)
    )
  }

  func testRecentAuthenticationReturnsFreshTokenForTheCurrentProductAccount() async throws {
    let response = ProductAccountConnectResponse(
      accountCreated: true,
      deviceRegistered: false,
      productSyncMaterialInitialized: false,
      productAccountId: Self.restorableSnapshot.productAccountId,
      trustedDeviceId: Self.restorableSnapshot.trustedDeviceId
    )
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: Self.restorableSnapshot.appleUserIdentifier,
          identityToken: "fresh-token"
        )
      ),
      productAccountService: PreviewProductAccountService(response: response),
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore
    )
    try store.save(Self.restorableSnapshot)
    await session.bootstrap()
    guard case .signedIn(let currentSnapshot) = session.state else {
      return XCTFail("Expected signed-in state")
    }

    let token = try await session.recentIdentityToken(
      for: currentSnapshot
    )

    XCTAssertEqual(token, "fresh-token")
  }

  func testTrustedDeviceDisplayNameUsesTheBackendUTF16Limit() {
    let displayName = TrustedDeviceIdentity.normalizedDisplayName(
      String(repeating: "😀", count: 50),
      platform: "ios"
    )

    XCTAssertEqual(displayName.count, 40)
    XCTAssertEqual(displayName.utf16.count, 80)
    let oversizedFirstCharacter = "a" + String(repeating: "\u{0301}", count: 80)
    XCTAssertEqual(
      TrustedDeviceIdentity.normalizedDisplayName(oversizedFirstCharacter, platform: "ios"),
      "This Apple Device"
    )
  }

  func testAuthenticationPresentationAnchorsPreserveKeyWindowAcrossActiveScenesOffMainThread() {
    let callbackInput = makeAuthenticationPresentationFixture()
    let callbackCompleted = expectation(description: "Presentation callbacks complete")

    DispatchQueue.global().async {
      XCTAssertFalse(Thread.isMainThread)
      let authorizationController = ASAuthorizationController(
        authorizationRequests: [ASAuthorizationAppleIDProvider().createRequest()]
      )
      let webAuthenticationSession = ASWebAuthenticationSession(
        url: URL(string: "https://example.test")!,
        callbackURLScheme: nil
      ) { _, _ in }
      let appleAnchor = callbackInput.appleProvider.presentationAnchor(
        for: authorizationController
      )
      XCTAssertTrue(appleAnchor === callbackInput.authenticationWindow)
      for provider in callbackInput.webProviders {
        let webAnchor = provider.presentationAnchor(for: webAuthenticationSession)
        XCTAssertTrue(webAnchor === callbackInput.authenticationWindow)
      }
      callbackCompleted.fulfill()
    }

    wait(for: [callbackCompleted], timeout: 1)
  }

  private func makeAuthenticationPresentationFixture() -> AuthenticationPresentationFixture {
    let otherWindow = ASPresentationAnchor()
    let authenticationWindow = ASPresentationAnchor()
    let presentationAnchorStore = AuthenticationPresentationAnchorStore {
      AuthenticationPresentationAnchor.preferredAnchor(
        in: [
          AuthenticationPresentationSceneSnapshot(
            isForegroundActive: true,
            windows: [.init(anchor: otherWindow, isKeyWindow: false)]
          ),
          AuthenticationPresentationSceneSnapshot(
            isForegroundActive: true,
            windows: [.init(anchor: authenticationWindow, isKeyWindow: true)]
          ),
        ]
      )
    }
    XCTAssertTrue(presentationAnchorStore.captureCurrent())
    return AuthenticationPresentationFixture(
      appleProvider: SignInWithAppleService(
        presentationAnchorStore: presentationAnchorStore
      ),
      authenticationWindow: authenticationWindow,
      webProviders: [
        GoogleGmailOAuthService(
          clientIdentifier: nil,
          presentationAnchorStore: presentationAnchorStore
        ),
        MicrosoftGraphOAuthService(
          callbackScheme: nil,
          clientIdentifier: nil,
          presentationAnchorStore: presentationAnchorStore
        ),
      ]
    )
  }

  func testMailboxFreshnessViewModelIsSharedAcrossSessionViews() {
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: "apple-user-001",
          identityToken: "token-001"
        )
      ),
      sessionStore: store
    )

    let mailViewModel = session.sharedMailboxFreshnessViewModel(
      for: Self.restorableSnapshot,
      service: MailboxConnectionRouter()
    )
    let settingsViewModel = session.sharedMailboxFreshnessViewModel(
      for: Self.restorableSnapshot,
      service: MailboxConnectionRouter()
    )

    XCTAssertTrue(mailViewModel === settingsViewModel)
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

  func testSignInRejectsOverlapAndIgnoresUnrelatedControllerCompletion() async throws {
    var controllers: [ASAuthorizationController] = []
    let firstRequestStarted = expectation(description: "First authorization request started")
    let retryRequestStarted = expectation(description: "Retry authorization request started")
    let service = SignInWithAppleService(
      performAuthorizationRequest: {
        controllers.append($0)
        if controllers.count == 1 {
          firstRequestStarted.fulfill()
        } else {
          retryRequestStarted.fulfill()
        }
      }
    )
    let firstSignIn = Task { try await service.signIn() }
    await fulfillment(of: [firstRequestStarted])
    let activeController = try XCTUnwrap(controllers.first)
    let unrelatedController = ASAuthorizationController(
      authorizationRequests: [ASAuthorizationAppleIDProvider().createRequest()]
    )

    service.authorizationController(
      controller: unrelatedController,
      didCompleteWithError: CancellationError()
    )

    do {
      _ = try await service.signIn()
      XCTFail("Expected overlapping authorization to be rejected")
    } catch {
      XCTAssertEqual(error as? AppleSignInError, .authorizationInProgress)
    }

    service.authorizationController(
      controller: activeController,
      didCompleteWithError: CancellationError()
    )
    do {
      _ = try await firstSignIn.value
      XCTFail("Expected the active authorization to be cancelled")
    } catch is CancellationError {
    }

    let retrySignIn = Task { try await service.signIn() }
    await fulfillment(of: [retryRequestStarted])
    let retryController = try XCTUnwrap(controllers.last)
    service.authorizationController(
      controller: retryController,
      didCompleteWithError: CancellationError()
    )
    do {
      _ = try await retrySignIn.value
      XCTFail("Expected the retry authorization to be cancelled")
    } catch is CancellationError {
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
    let productAccountService = RecordingProductAccountService(response: .preview)
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: "apple-user-001",
          identityToken: "token-001"
        )
      ),
      devicePushUnregistrationService: pushUnregisterer,
      productAccountService: productAccountService,
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
    XCTAssertEqual(
      productAccountService.unregisteredTrustedDeviceIds,
      [ProductAccountConnectResponse.preview.trustedDeviceId]
    )
    XCTAssertNil(
      try keyMaterialStore.load(
        productAccountId: ProductAccountConnectResponse.preview.productAccountId
      )
    )
  }

  func testSignOutPreservesSessionAndKeysUntilRecoveryIsBackedUp() async throws {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    let material = try keyMaterialStore.ensureMaterial(
      productAccountId: snapshot.productAccountId,
      allowCreation: true
    )
    let gmailConnectionService = RecordingGmailProviderConnecting()
    let productAccountService = RecordingProductAccountService(response: .preview)
    productAccountService.recoveryBackedUp = false
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: "fresh-token"
        )
      ),
      devicePushUnregistrationService: pushUnregisterer,
      productAccountService: productAccountService,
      sessionStore: store,
      mailboxConnectionService: gmailConnectionService,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    var didPrepareDestructiveCleanup = false
    await session.signOut {
      didPrepareDestructiveCleanup = true
    }

    XCTAssertEqual(session.state, .signedIn(snapshot))
    XCTAssertEqual(
      session.signOutErrorMessage,
      ProductAccountSessionError.recoveryNotBackedUp.localizedDescription
    )
    XCTAssertEqual(try store.load(), snapshot)
    XCTAssertEqual(
      try keyMaterialStore.load(productAccountId: snapshot.productAccountId),
      material
    )
    XCTAssertEqual(gmailConnectionService.clearedSessions, [])
    XCTAssertEqual(pushUnregisterer.sessions, [])
    XCTAssertEqual(productAccountService.unregisteredTrustedDeviceIds, [])
    XCTAssertEqual(
      productAccountService.recoveryCheckExpectedWrappedAccountKeys,
      [material.recoveryWrappedAccountKey]
    )
    XCTAssertFalse(didPrepareDestructiveCleanup)
  }

  func testSignOutUsesRefreshedIdentityTokenForAllRemoteCleanup() async throws {
    let snapshot = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "expired-token",
      identityTokenExpiresAt: .distantPast,
      productAccountId: "product-account-001",
      trustedDeviceId: "trusted-device-001"
    )
    try store.save(snapshot)
    let mailboxConnectionService = RecordingGmailProviderConnecting()
    let productAccountService = RecordingProductAccountService(response: .preview)
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: "fresh-token"
        )
      ),
      devicePushUnregistrationService: pushUnregisterer,
      productAccountService: productAccountService,
      sessionStore: store,
      mailboxConnectionService: mailboxConnectionService,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.signOut()

    XCTAssertEqual(productAccountService.recoveryCheckIdentityTokens, ["fresh-token"])
    XCTAssertEqual(productAccountService.unregistrationIdentityTokens, ["fresh-token"])
    XCTAssertEqual(pushUnregisterer.sessions.map(\.identityToken), ["fresh-token"])
    XCTAssertEqual(mailboxConnectionService.clearedSessions.map(\.identityToken), ["fresh-token"])
    XCTAssertEqual(session.state, .signedOut)
  }

  func testSignOutRefreshesIdentityTokenThatExpiresDuringCleanup() async throws {
    let snapshot = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "nearly-expired-token",
      identityTokenExpiresAt: Date().addingTimeInterval(60),
      productAccountId: "product-account-001",
      trustedDeviceId: "trusted-device-001"
    )
    try store.save(snapshot)
    let productAccountService = RecordingProductAccountService(response: .preview)
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: "fresh-token"
        )
      ),
      devicePushUnregistrationService: pushUnregisterer,
      productAccountService: productAccountService,
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.signOut()

    XCTAssertEqual(productAccountService.recoveryCheckIdentityTokens, ["fresh-token"])
    XCTAssertEqual(productAccountService.unregistrationIdentityTokens, ["fresh-token"])
    XCTAssertEqual(session.state, .signedOut)
  }

  func testSignOutWaitsForRecoveryPublicationForTheSameAccount() async throws {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      devicePushUnregistrationService: pushUnregisterer,
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore
    )
    await session.bootstrap()
    guard case .signedIn(let activeSnapshot) = session.state else {
      return XCTFail("Expected bootstrap to restore the Product Account")
    }
    await productAccountRecoveryOperationGate.acquire(
      productAccountId: activeSnapshot.productAccountId
    )

    let signOut = Task { await session.signOut() }
    await waitForRecoveryOperationWaiter(
      productAccountId: activeSnapshot.productAccountId
    )

    XCTAssertEqual(session.state, .signedIn(activeSnapshot))

    await productAccountRecoveryOperationGate.release(
      productAccountId: activeSnapshot.productAccountId
    )
    await signOut.value
    XCTAssertEqual(session.state, .signedOut)
  }

  func testSignOutRefusesToDiscardAnUnacknowledgedRecoveryKey() async throws {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore
    )
    await session.bootstrap()
    guard case .signedIn(let activeSnapshot) = session.state else {
      return XCTFail("Expected bootstrap to restore the Product Account")
    }
    try session.preserveUnacknowledgedRecoveryKey("unacknowledged-key")

    await session.signOut()

    XCTAssertEqual(session.state, .signedIn(activeSnapshot))
    XCTAssertEqual(
      session.signOutErrorMessage,
      ProductAccountSessionError.recoveryNotBackedUp.localizedDescription
    )
    XCTAssertEqual(session.unacknowledgedRecoveryKey, "unacknowledged-key")
  }

  func testRecoveryKeyCannotReplaceActiveMarkerForNoLongerCurrentWrapper() async throws {
    let snapshot = Self.restorableSnapshot
    let productAccountId = ProductAccountConnectResponse.preview.productAccountId
    try store.save(snapshot)
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore
    )
    await session.bootstrap()
    try session.preserveUnacknowledgedRecoveryKey("first-key")
    let material = try XCTUnwrap(
      keyMaterialStore.load(productAccountId: productAccountId)
    )
    try keyMaterialStore.save(
      material.replacingRecoveryKey(),
      productAccountId: productAccountId
    )

    XCTAssertThrowsError(try session.preserveUnacknowledgedRecoveryKey("second-key")) { error in
      XCTAssertEqual(error as? ProductAccountSessionError, .recoveryKeyUnacknowledged)
    }

    XCTAssertEqual(session.unacknowledgedRecoveryKey, "first-key")
    let persistedMarker = try store.loadUnacknowledgedRecoveryKey(
      productAccountId: productAccountId
    )
    XCTAssertEqual(persistedMarker?.recoveryKey, "first-key")
  }

  func testSignOutRemainsBlockedWhenRecoveryKeyPersistenceFails() async throws {
    let snapshot = Self.restorableSnapshot
    let failingStore = ControllableProductAccountSessionStore(snapshot: snapshot)
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: failingStore,
      productSyncKeyMaterialStore: keyMaterialStore
    )
    await session.bootstrap()
    guard case .signedIn(let activeSnapshot) = session.state else {
      return XCTFail("Expected bootstrap to restore the Product Account")
    }
    failingStore.unacknowledgedRecoveryKeySaveError =
      ProductAccountSessionTestError.sessionSaveFailed

    XCTAssertThrowsError(try session.preserveUnacknowledgedRecoveryKey("published-key"))
    await session.signOut()

    XCTAssertEqual(session.state, .signedIn(activeSnapshot))
    XCTAssertEqual(session.unacknowledgedRecoveryKey, "published-key")
    XCTAssertEqual(
      session.signOutErrorMessage,
      ProductAccountSessionError.recoveryNotBackedUp.localizedDescription
    )

    try session.acknowledgeRecoveryKey(
      "published-key",
      productAccountId: activeSnapshot.productAccountId
    )
    await session.signOut()

    XCTAssertEqual(session.state, .signedOut)
    XCTAssertNil(session.unacknowledgedRecoveryKey)
  }

  func testSignOutRefusesUnacknowledgedRecoveryKeyAfterSessionRecreation() async throws {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: snapshot.productAccountId,
      allowCreation: true
    )
    let appleSignInService = PreviewAppleSignInService(
      credential: AppleSignInCredential(
        appleUserIdentifier: snapshot.appleUserIdentifier,
        identityToken: snapshot.identityToken
      )
    )
    let firstSession = ProductAccountSession(
      appleSignInService: appleSignInService,
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore
    )
    try firstSession.preserveUnacknowledgedRecoveryKey("unacknowledged-key")

    let response = ProductAccountConnectResponse(
      accountCreated: false,
      deviceRegistered: true,
      productSyncMaterialInitialized: true,
      productAccountId: snapshot.productAccountId,
      trustedDeviceId: snapshot.trustedDeviceId
    )
    let relaunchedSession = ProductAccountSession(
      appleSignInService: appleSignInService,
      productAccountService: PreviewProductAccountService(response: response),
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore
    )
    await relaunchedSession.bootstrap()
    XCTAssertEqual(relaunchedSession.unacknowledgedRecoveryKey, "unacknowledged-key")

    await relaunchedSession.signOut()

    XCTAssertEqual(relaunchedSession.state, .signedIn(snapshot))
    XCTAssertEqual(
      relaunchedSession.signOutErrorMessage,
      ProductAccountSessionError.recoveryNotBackedUp.localizedDescription
    )

    try relaunchedSession.acknowledgeRecoveryKey(
      "unacknowledged-key",
      productAccountId: snapshot.productAccountId
    )
    XCTAssertNil(
      try store.loadUnacknowledgedRecoveryKey(productAccountId: snapshot.productAccountId)
    )
  }

  func testLegacyRecoveryKeyRemainsVisibleAndBlocksSignOutAfterRelaunch() async throws {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: snapshot.productAccountId,
      allowCreation: true
    )
    try store.saveUnacknowledgedRecoveryKey(
      UnacknowledgedRecoveryKey(
        recoveryKey: "legacy-key",
        recoveryWrappedAccountKey: nil
      ),
      productAccountId: snapshot.productAccountId
    )
    let response = ProductAccountConnectResponse(
      accountCreated: false,
      deviceRegistered: true,
      productSyncMaterialInitialized: true,
      productAccountId: snapshot.productAccountId,
      trustedDeviceId: snapshot.trustedDeviceId
    )
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      productAccountService: PreviewProductAccountService(response: response),
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.bootstrap()

    XCTAssertEqual(session.unacknowledgedRecoveryKey, "legacy-key")

    await session.signOut()

    XCTAssertEqual(session.state, .signedIn(snapshot))
    XCTAssertEqual(session.unacknowledgedRecoveryKey, "legacy-key")
    XCTAssertEqual(
      session.signOutErrorMessage,
      ProductAccountSessionError.recoveryNotBackedUp.localizedDescription
    )

    try session.acknowledgeRecoveryKey(
      "legacy-key",
      productAccountId: snapshot.productAccountId
    )
    XCTAssertNil(session.unacknowledgedRecoveryKey)
    XCTAssertNil(
      try store.loadUnacknowledgedRecoveryKey(productAccountId: snapshot.productAccountId)
    )
  }

  func testRelaunchDoesNotPresentRecoveryKeyBoundToDifferentWrapper() async throws {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: snapshot.productAccountId,
      allowCreation: true
    )
    let rejectedMaterial = try ProductSyncKeyMaterial.create()
    try store.saveUnacknowledgedRecoveryKey(
      UnacknowledgedRecoveryKey(
        recoveryKey: rejectedMaterial.recoveryKey.rawValue,
        recoveryWrappedAccountKey: rejectedMaterial.recoveryWrappedAccountKey
      ),
      productAccountId: snapshot.productAccountId
    )
    let response = ProductAccountConnectResponse(
      accountCreated: false,
      deviceRegistered: true,
      productSyncMaterialInitialized: true,
      productAccountId: snapshot.productAccountId,
      trustedDeviceId: snapshot.trustedDeviceId
    )
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      productAccountService: PreviewProductAccountService(response: response),
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.bootstrap()

    XCTAssertNil(session.unacknowledgedRecoveryKey)

    try session.preserveUnacknowledgedRecoveryKey("replacement-key")

    XCTAssertEqual(session.unacknowledgedRecoveryKey, "replacement-key")
    XCTAssertEqual(
      try store.loadUnacknowledgedRecoveryKey(productAccountId: snapshot.productAccountId)?
        .recoveryKey,
      "replacement-key"
    )
  }

  func testAcknowledgingOlderRecoveryKeyDoesNotClearNewerKey() async throws {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    let response = ProductAccountConnectResponse(
      accountCreated: false,
      deviceRegistered: true,
      productSyncMaterialInitialized: true,
      productAccountId: snapshot.productAccountId,
      trustedDeviceId: snapshot.trustedDeviceId
    )
    let material = try keyMaterialStore.ensureMaterial(
      productAccountId: snapshot.productAccountId,
      allowCreation: true
    )
    try store.saveUnacknowledgedRecoveryKey(
      UnacknowledgedRecoveryKey(
        recoveryKey: "older-key",
        recoveryWrappedAccountKey: material.recoveryWrappedAccountKey
      ),
      productAccountId: snapshot.productAccountId
    )
    try keyMaterialStore.save(
      material.replacingRecoveryKey(),
      productAccountId: snapshot.productAccountId
    )
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      productAccountService: PreviewProductAccountService(response: response),
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore
    )
    await session.bootstrap()
    try session.preserveUnacknowledgedRecoveryKey("newer-key")

    try session.acknowledgeRecoveryKey(
      "older-key",
      productAccountId: snapshot.productAccountId
    )

    XCTAssertEqual(session.unacknowledgedRecoveryKey, "newer-key")
    XCTAssertEqual(
      try store.loadUnacknowledgedRecoveryKey(productAccountId: snapshot.productAccountId)?
        .recoveryKey,
      "newer-key"
    )
  }

  // swiftlint:disable:next function_body_length
  func testSignOutCompletesWhenTrustedDeviceUnregistrationFails() async throws {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    let gmailConnectionService = RecordingGmailProviderConnecting()
    let productAccountService = RecordingProductAccountService(response: .preview)
    productAccountService.unregisterError =
      ProductAccountSessionTestError.trustedDeviceUnregistrationFailed
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      devicePushUnregistrationService: pushUnregisterer,
      productAccountService: productAccountService,
      sessionStore: store,
      mailboxConnectionService: gmailConnectionService,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.signOut()

    XCTAssertEqual(session.state, .signedOut)
    XCTAssertNil(try store.load())
    XCTAssertEqual(gmailConnectionService.clearedSessions, [snapshot])
    XCTAssertEqual(
      try store.loadPendingTrustedDeviceUnregistrations(),
      [
        PendingTrustedDeviceUnregistration(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          productAccountId: snapshot.productAccountId,
          trustedDeviceId: snapshot.trustedDeviceId
        )
      ]
    )

    productAccountService.unregisterError = nil
    let relaunchedSession = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      devicePushUnregistrationService: pushUnregisterer,
      productAccountService: productAccountService,
      sessionStore: store,
      mailboxConnectionService: gmailConnectionService,
      productSyncKeyMaterialStore: keyMaterialStore
    )
    await relaunchedSession.bootstrap()

    XCTAssertEqual(relaunchedSession.state, .signedOut)
    XCTAssertEqual(try store.loadPendingTrustedDeviceUnregistrations().count, 1)
    XCTAssertEqual(
      productAccountService.unregisteredTrustedDeviceIds,
      [snapshot.trustedDeviceId]
    )

    await relaunchedSession.signInWithApple()

    XCTAssertTrue(try store.loadPendingTrustedDeviceUnregistrations().isEmpty)
    XCTAssertEqual(
      productAccountService.unregisteredTrustedDeviceIds,
      [snapshot.trustedDeviceId, snapshot.trustedDeviceId]
    )
  }

  func testBootstrapDoesNotPromptForPendingTrustedDeviceUnregistration() async throws {
    try store.savePendingTrustedDeviceUnregistration(
      PendingTrustedDeviceUnregistration(
        appleUserIdentifier: "apple-user-001",
        productAccountId: "product-account-001",
        trustedDeviceId: "trusted-device-001"
      )
    )
    let appleSignInService = RevokedAppleSignInService()
    let session = ProductAccountSession(
      appleSignInService: appleSignInService,
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.bootstrap()
    let signInCallCount = await appleSignInService.signInCallCount

    XCTAssertEqual(session.state, .signedOut)
    XCTAssertEqual(try store.loadPendingTrustedDeviceUnregistrations().count, 1)
    XCTAssertEqual(signInCallCount, 0)
  }

  func testExplicitSignInRetriesEveryPendingTrustedDeviceForAppleAccount() async throws {
    let first = PendingTrustedDeviceUnregistration(
      appleUserIdentifier: "apple-user-001",
      productAccountId: "product-account-001",
      trustedDeviceId: "trusted-device-001"
    )
    let second = PendingTrustedDeviceUnregistration(
      appleUserIdentifier: "apple-user-001",
      productAccountId: "product-account-002",
      trustedDeviceId: "trusted-device-002"
    )
    try store.savePendingTrustedDeviceUnregistration(first)
    try store.savePendingTrustedDeviceUnregistration(second)
    let productAccountService = RecordingProductAccountService(response: .preview)
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: "apple-user-001",
          identityToken: "fresh-token"
        )
      ),
      productAccountService: productAccountService,
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.signInWithApple()

    XCTAssertTrue(try store.loadPendingTrustedDeviceUnregistrations().isEmpty)
    XCTAssertEqual(
      Set(productAccountService.unregisteredTrustedDeviceIds),
      Set([first.trustedDeviceId, second.trustedDeviceId])
    )
  }

  func testSignOutExitsSignedInStateBeforeSharedCleanup() async throws {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    let cleanupGate = SignOutUnregistrationGate()
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      devicePushUnregistrationService: SuspendingDevicePushUnregisterer(gate: cleanupGate),
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    let signOut = Task { await session.signOut() }
    await cleanupGate.waitUntilStarted()

    XCTAssertEqual(session.state, .loading)

    await cleanupGate.release()
    await signOut.value
    XCTAssertEqual(session.state, .signedOut)
  }

  func testConcurrentSignOutRequestsShareOneCleanupOperation() async throws {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    let cleanupGate = SignOutUnregistrationGate()
    let mailboxConnectionService = RecordingGmailProviderConnecting()
    let productAccountService = RecordingProductAccountService(response: .preview)
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      devicePushUnregistrationService: SuspendingDevicePushUnregisterer(gate: cleanupGate),
      productAccountService: productAccountService,
      sessionStore: store,
      mailboxConnectionService: mailboxConnectionService,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    let firstSignOut = Task { await session.signOut() }
    await cleanupGate.waitUntilStarted()
    let secondRequested = expectation(description: "second sign-out requested")
    let secondSignOut = Task {
      secondRequested.fulfill()
      await session.signOut {
        XCTFail("A concurrent sign-out must not run separate preparation.")
      }
    }
    await fulfillment(of: [secondRequested], timeout: 1)
    await cleanupGate.release()
    await firstSignOut.value
    await secondSignOut.value

    XCTAssertEqual(productAccountService.recoveryCheckCount, 1)
    XCTAssertEqual(productAccountService.unregisteredTrustedDeviceIds, [snapshot.trustedDeviceId])
    XCTAssertEqual(mailboxConnectionService.clearedSessions, [snapshot])
    XCTAssertEqual(session.state, .signedOut)
  }

  func testBeginSignOutImmediatelyExitsSignedInState() async throws {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      devicePushUnregistrationService: pushUnregisterer,
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore
    )
    await session.bootstrap()

    session.beginSignOut()

    XCTAssertEqual(session.state, .loading)
    XCTAssertFalse(session.isCurrent(snapshot))
    await session.signOut()
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
    let signInTask = Task { await session.signInWithApple() }
    await waitForRecoveryOperationWaiter(productAccountId: oldSnapshot.productAccountId)
    await unregistrationGate.release()
    await signOutTask.value
    await signInTask.value
    guard case .signedIn(let newSnapshot) = session.state else {
      return XCTFail("Expected concurrent sign-in to complete")
    }

    XCTAssertEqual(session.state, .signedIn(newSnapshot))
    XCTAssertEqual(try store.load(), newSnapshot)
    XCTAssertEqual(gmailConnectionService.clearedSessions, [newSnapshot])
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
    let signInTask = Task { await session.signInWithApple() }
    await waitForRecoveryOperationWaiter(productAccountId: oldSnapshot.productAccountId)
    await gmailCleanupGate.release()
    await signOutTask.value
    await signInTask.value
    guard case .signedIn(let newSnapshot) = session.state else {
      return XCTFail("Expected concurrent sign-in to complete")
    }

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
    let productAccountService = RecordingProductAccountService(response: .preview)
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: "apple-user-001",
          identityToken: "token-001"
        )
      ),
      devicePushUnregistrationService: pushUnregisterer,
      productAccountService: productAccountService,
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
    XCTAssertTrue(productAccountService.unregisteredTrustedDeviceIds.isEmpty)
  }

  func testSignOutLeavesPendingCleanupWhenProductSyncKeyCleanupFails() async throws {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: snapshot.productAccountId,
      allowCreation: true
    )
    keyMaterialStore.clearError = ProductAccountSessionTestError.keyCleanupFailed
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      devicePushUnregistrationService: pushUnregisterer,
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.signOut()

    XCTAssertEqual(
      session.state,
      .failed(ProductAccountSessionTestError.keyCleanupFailed.localizedDescription)
    )
    XCTAssertNil(try store.load())
    XCTAssertNotNil(
      try keyMaterialStore.load(productAccountId: snapshot.productAccountId)
    )
    XCTAssertEqual(
      try store.loadPendingSignOutProductAccountId(),
      snapshot.productAccountId
    )
  }

  func testSignOutPersistsCleanupIntentBeforeTrustedDeviceUnregistration() async throws {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    let productAccountService = RecordingProductAccountService(response: .preview)
    var pendingAccountIdAtUnregistration: String?
    productAccountService.unregistrationAction = {
      pendingAccountIdAtUnregistration = try? self.store.loadPendingSignOutProductAccountId()
    }
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      devicePushUnregistrationService: pushUnregisterer,
      productAccountService: productAccountService,
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.signOut()

    XCTAssertEqual(pendingAccountIdAtUnregistration, snapshot.productAccountId)
  }

  func testSignOutPersistsCleanupIntentBeforeProviderAndMailboxCleanup() async throws {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    var pendingAccountIdAtPushCleanup: String?
    var pendingAccountIdAtMailboxCleanup: String?
    pushUnregisterer.action = {
      pendingAccountIdAtPushCleanup = try? self.store.loadPendingSignOutProductAccountId()
    }
    let mailboxConnectionService = RecordingGmailProviderConnecting()
    mailboxConnectionService.clearAction = {
      pendingAccountIdAtMailboxCleanup = try? self.store.loadPendingSignOutProductAccountId()
    }
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      devicePushUnregistrationService: pushUnregisterer,
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: store,
      mailboxConnectionService: mailboxConnectionService,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.signOut()

    XCTAssertEqual(pendingAccountIdAtPushCleanup, snapshot.productAccountId)
    XCTAssertEqual(pendingAccountIdAtMailboxCleanup, snapshot.productAccountId)
  }

  func testSignOutPersistsCleanupIntentBeforePreparation() async throws {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore
    )
    var pendingAccountIdDuringPreparation: String?

    await session.signOut {
      pendingAccountIdDuringPreparation = try? self.store.loadPendingSignOutProductAccountId()
    }

    XCTAssertEqual(pendingAccountIdDuringPreparation, snapshot.productAccountId)
  }

  func testSignOutLeavesPendingCleanupWhenSessionCleanupFails() async throws {
    let snapshot = Self.restorableSnapshot
    let sessionStore = ControllableProductAccountSessionStore(snapshot: snapshot)
    sessionStore.clearError = ProductAccountSessionTestError.sessionClearFailed
    let material = try keyMaterialStore.ensureMaterial(
      productAccountId: snapshot.productAccountId,
      allowCreation: true
    )
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      devicePushUnregistrationService: pushUnregisterer,
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: sessionStore,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.signOut()

    XCTAssertEqual(
      session.state,
      .failed(ProductAccountSessionTestError.sessionClearFailed.localizedDescription)
    )
    XCTAssertEqual(try sessionStore.load(), snapshot)
    XCTAssertEqual(
      try keyMaterialStore.load(productAccountId: snapshot.productAccountId),
      material
    )
    XCTAssertEqual(
      try sessionStore.loadPendingSignOutProductAccountId(),
      snapshot.productAccountId
    )
  }

  func testBootstrapCompletesInterruptedSignOut() async throws {
    let snapshot = ProductAccountSessionSnapshot(
      appleUserIdentifier: Self.restorableSnapshot.appleUserIdentifier,
      identityToken: "active-token",
      identityTokenExpiresAt: .distantFuture,
      productAccountId: Self.restorableSnapshot.productAccountId,
      trustedDeviceId: Self.restorableSnapshot.trustedDeviceId
    )
    let sessionStore = ControllableProductAccountSessionStore(snapshot: snapshot)
    try sessionStore.savePendingSignOutProductAccountId(snapshot.productAccountId)
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: snapshot.productAccountId,
      allowCreation: true
    )
    let mailboxConnectionService = RecordingGmailProviderConnecting()
    let productAccountService = RecordingProductAccountService(response: .preview)
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      devicePushUnregistrationService: pushUnregisterer,
      productAccountService: productAccountService,
      sessionStore: sessionStore,
      mailboxConnectionService: mailboxConnectionService,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.bootstrap()

    XCTAssertEqual(session.state, .signedOut)
    XCTAssertNil(try sessionStore.load())
    XCTAssertNil(
      try keyMaterialStore.load(productAccountId: snapshot.productAccountId)
    )
    XCTAssertNil(try sessionStore.loadPendingSignOutProductAccountId())
    XCTAssertEqual(pushUnregisterer.sessions, [snapshot])
    XCTAssertEqual(mailboxConnectionService.clearedSessions, [snapshot])
    XCTAssertEqual(productAccountService.unregisteredTrustedDeviceIds, [snapshot.trustedDeviceId])
  }

  func testBootstrapDoesNotPromptForInterruptedSignOutWithUnverifiableToken() async throws {
    let snapshot = Self.restorableSnapshot
    let sessionStore = ControllableProductAccountSessionStore(snapshot: snapshot)
    try sessionStore.savePendingSignOutProductAccountId(snapshot.productAccountId)
    let appleSignInService = RevokedAppleSignInService()
    let productAccountService = RecordingProductAccountService(response: .preview)
    let session = ProductAccountSession(
      appleSignInService: appleSignInService,
      devicePushUnregistrationService: pushUnregisterer,
      productAccountService: productAccountService,
      sessionStore: sessionStore,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.bootstrap()
    let signInCallCount = await appleSignInService.signInCallCount

    XCTAssertEqual(session.state, .signedOut)
    XCTAssertEqual(signInCallCount, 0)
    XCTAssertNil(try sessionStore.load())
    XCTAssertEqual(
      try sessionStore.loadPendingTrustedDeviceUnregistrations(),
      [
        PendingTrustedDeviceUnregistration(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          productAccountId: snapshot.productAccountId,
          trustedDeviceId: snapshot.trustedDeviceId
        )
      ]
    )
    XCTAssertTrue(productAccountService.unregistrationIdentityTokens.isEmpty)
  }

  func testBootstrapRetainsRetryWhenInterruptedSignOutUnregistrationFails() async throws {
    let snapshot = Self.restorableSnapshot
    let sessionStore = ControllableProductAccountSessionStore(snapshot: snapshot)
    try sessionStore.savePendingSignOutProductAccountId(snapshot.productAccountId)
    let productAccountService = RecordingProductAccountService(response: .preview)
    productAccountService.unregisterError =
      ProductAccountSessionTestError.trustedDeviceUnregistrationFailed
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: "fresh-token"
        )
      ),
      productAccountService: productAccountService,
      sessionStore: sessionStore,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.bootstrap()

    XCTAssertEqual(session.state, .signedOut)
    XCTAssertEqual(
      try sessionStore.loadPendingTrustedDeviceUnregistrations(),
      [
        PendingTrustedDeviceUnregistration(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          productAccountId: snapshot.productAccountId,
          trustedDeviceId: snapshot.trustedDeviceId
        )
      ]
    )
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
      identityToken: "expired-token",
      identityTokenExpiresAt: .distantPast,
      productAccountId: "productAccountFixtureId",
      trustedDeviceId: "trustedDeviceFixtureId"
    )
    try store.save(snapshot)
    try store.saveUnacknowledgedRecoveryKey(
      UnacknowledgedRecoveryKey(
        recoveryKey: "unacknowledged-key",
        recoveryWrappedAccountKey: nil
      ),
      productAccountId: snapshot.productAccountId
    )
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: snapshot.productAccountId,
      allowCreation: true
    )
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
    XCTAssertNil(
      try keyMaterialStore.load(productAccountId: snapshot.productAccountId)
    )
    XCTAssertNil(try store.loadPendingSignOutProductAccountId())
    XCTAssertNil(
      try store.loadUnacknowledgedRecoveryKey(productAccountId: snapshot.productAccountId)
    )
    XCTAssertEqual(gmailConnectionService.clearedSession, snapshot)
    XCTAssertEqual(pushUnregisterer.sessions, [])
  }

  func testBootstrapRunsOnlyOnceForSharedMultiWindowSession() async {
    let countingStore = ControllableProductAccountSessionStore()
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: "apple-user-001",
          identityToken: "token-001"
        )
      ),
      sessionStore: countingStore
    )

    await session.bootstrap()
    await session.bootstrap()

    XCTAssertEqual(session.state, .signedOut)
    XCTAssertEqual(countingStore.loadCount, 1)
  }

  func testBootstrapSurvivesCancellationOfFirstWindowCaller() async throws {
    let snapshot = Self.restorableSnapshot
    let countingStore = ControllableProductAccountSessionStore(snapshot: snapshot)
    let restoreGate = BootstrapRestoreGate()
    let session = ProductAccountSession(
      appleSignInService: SuspendingAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        ),
        gate: restoreGate
      ),
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: countingStore,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    let firstWindowBootstrap = Task { await session.bootstrap() }
    await restoreGate.waitUntilStarted()
    let survivingWindowBootstrap = Task { await session.bootstrap() }
    firstWindowBootstrap.cancel()
    await restoreGate.release()
    await survivingWindowBootstrap.value
    await firstWindowBootstrap.value

    guard case .signedIn = session.state else {
      return XCTFail("Expected the shared bootstrap to finish for the surviving window.")
    }
    XCTAssertEqual(countingStore.loadCount, 1)
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

  func testExistingProductAccountRestoresProductSyncMaterialWithRecoveryKey() async throws {
    let original = try ProductSyncKeyMaterial.create(
      accountKeyData: Data(repeating: 21, count: ProductSyncKeyMaterial.keyByteCount),
      recoveryKeyData: Data(repeating: 22, count: ProductSyncKeyMaterial.keyByteCount)
    )
    let productAccountService = RecordingProductAccountService(response: .resumed)
    productAccountService.recoveryMaterial = EncryptedProductSyncPayload(
      encryptedPayload: original.recoveryWrappedAccountKey,
      payloadIdentifier: AccountAndDevicesService.recoveryPayloadIdentifier,
      updatedAt: 1
    )
    let appleSignInService = SequencedAppleSignInService(
      credentials: [
        AppleSignInCredential(
          appleUserIdentifier: "apple-user-001",
          identityToken: "stale-token"
        ),
        AppleSignInCredential(
          appleUserIdentifier: "apple-user-001",
          identityToken: "fresh-token"
        ),
      ]
    )
    let session = ProductAccountSession(
      appleSignInService: appleSignInService,
      productAccountService: productAccountService,
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.signInWithApple()

    XCTAssertTrue(session.requiresProductSyncRecovery)
    guard case .failed = session.state else {
      return XCTFail("Expected Recovery Key prompt state")
    }

    await session.restoreProductSyncMaterial(recoveryKey: " \n\(original.recoveryKey.rawValue)\t")

    guard case .signedIn(let snapshot) = session.state else {
      return XCTFail("Expected signed-in state")
    }
    XCTAssertFalse(session.requiresProductSyncRecovery)
    XCTAssertEqual(
      snapshot.productAccountId,
      ProductAccountConnectResponse.resumed.productAccountId
    )
    XCTAssertEqual(
      try keyMaterialStore.load(productAccountId: snapshot.productAccountId)?.accountKeyData,
      original.accountKeyData
    )
    XCTAssertEqual(productAccountService.materialInitializationIdentityTokens, ["fresh-token"])
    XCTAssertEqual(
      productAccountService.recoveryMaterialIdentityTokens, ["stale-token", "fresh-token"])
  }

  // swiftlint:disable:next function_body_length
  func testSignOutWaitsForInFlightRecoveryRestoration() async throws {
    let original = try ProductSyncKeyMaterial.create(
      accountKeyData: Data(repeating: 31, count: ProductSyncKeyMaterial.keyByteCount),
      recoveryKeyData: Data(repeating: 32, count: ProductSyncKeyMaterial.keyByteCount)
    )
    let productAccountService = RecordingProductAccountService(response: .resumed)
    productAccountService.recoveryMaterial = EncryptedProductSyncPayload(
      encryptedPayload: original.recoveryWrappedAccountKey,
      payloadIdentifier: AccountAndDevicesService.recoveryPayloadIdentifier,
      updatedAt: 1
    )
    let restoreGate = BootstrapRestoreGate()
    let appleSignInService = SequencedSuspendingAppleSignInService(
      credentials: [
        AppleSignInCredential(
          appleUserIdentifier: "apple-user-001",
          identityToken: "initial-token"
        ),
        AppleSignInCredential(
          appleUserIdentifier: "apple-user-001",
          identityToken: "restore-token"
        ),
        AppleSignInCredential(
          appleUserIdentifier: "apple-user-001",
          identityToken: "sign-out-token"
        ),
      ],
      suspendedCallIndex: 1,
      gate: restoreGate
    )
    let session = ProductAccountSession(
      appleSignInService: appleSignInService,
      devicePushUnregistrationService: pushUnregisterer,
      productAccountService: productAccountService,
      sessionStore: store,
      mailboxConnectionService: RecordingGmailProviderConnecting(),
      productSyncKeyMaterialStore: keyMaterialStore
    )
    await session.signInWithApple()

    let restore = Task {
      await session.restoreProductSyncMaterial(recoveryKey: original.recoveryKey.rawValue)
    }
    await restoreGate.waitUntilStarted()
    let signOut = Task { await session.signOut() }
    await waitForRecoveryOperationWaiter(
      productAccountId: ProductAccountConnectResponse.resumed.productAccountId
    )

    await restoreGate.release()
    await restore.value
    await signOut.value

    XCTAssertEqual(session.state, .signedOut)
    XCTAssertFalse(session.requiresProductSyncRecovery)
    XCTAssertNil(try store.load())
  }

  func testRestartedSignInWaitsForPendingRecoveryRestoration() async throws {
    let original = try ProductSyncKeyMaterial.create()
    let productAccountService = RecordingProductAccountService(response: .resumed)
    productAccountService.recoveryMaterial = EncryptedProductSyncPayload(
      encryptedPayload: original.recoveryWrappedAccountKey,
      payloadIdentifier: AccountAndDevicesService.recoveryPayloadIdentifier,
      updatedAt: 1
    )
    let restoreGate = BootstrapRestoreGate()
    let appleSignInService = SequencedSuspendingAppleSignInService(
      credentials: [
        AppleSignInCredential(
          appleUserIdentifier: "apple-user-001",
          identityToken: "initial-token"
        ),
        AppleSignInCredential(
          appleUserIdentifier: "apple-user-001",
          identityToken: "restore-token"
        ),
        AppleSignInCredential(
          appleUserIdentifier: "apple-user-001",
          identityToken: "restart-token"
        ),
      ],
      suspendedCallIndex: 1,
      gate: restoreGate
    )
    let session = ProductAccountSession(
      appleSignInService: appleSignInService,
      productAccountService: productAccountService,
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore
    )
    await session.signInWithApple()

    let restore = Task {
      await session.restoreProductSyncMaterial(recoveryKey: original.recoveryKey.rawValue)
    }
    await restoreGate.waitUntilStarted()
    let restartedSignIn = Task { await session.signInWithApple() }
    await waitForRecoveryOperationWaiter(
      productAccountId: ProductAccountConnectResponse.resumed.productAccountId
    )

    await restoreGate.release()
    await restore.value
    await restartedSignIn.value

    guard case .signedIn(let snapshot) = session.state else {
      return XCTFail("Expected restarted sign-in to complete after recovery")
    }
    XCTAssertEqual(snapshot.identityToken, "restart-token")
    XCTAssertFalse(session.requiresProductSyncRecovery)
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

  func productSyncRecoveryIsBackedUp(
    identityToken _: String,
    expectedRecoveryWrappedAccountKey _: ProductSyncEncryptedPayload?
  ) async throws -> Bool {
    throw ConvexClientError.missingConvexURL
  }

  func unregisterTrustedDevice(
    identityToken: String,
    trustedDeviceId: String
  ) async throws -> TrustedDeviceUnregistrationResponse {
    _ = identityToken
    _ = trustedDeviceId
    throw ConvexClientError.missingConvexURL
  }
}

private actor RevokedAppleSignInService: AppleSignInPerforming {
  private(set) var signInCallCount = 0

  func signIn() async throws -> AppleSignInCredential {
    signInCallCount += 1
    throw AppleSignInError.notAuthorized
  }

  func restoreSession(
    snapshot: ProductAccountSessionSnapshot
  ) async throws -> AppleSignInCredential {
    _ = snapshot
    throw AppleSignInError.notAuthorized
  }
}

private actor BootstrapRestoreGate {
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

private struct SuspendingAppleSignInService: AppleSignInPerforming {
  let credential: AppleSignInCredential
  let gate: BootstrapRestoreGate

  func signIn() async throws -> AppleSignInCredential {
    credential
  }

  func restoreSession(
    snapshot _: ProductAccountSessionSnapshot
  ) async throws -> AppleSignInCredential {
    await gate.waitForRelease()
    return credential
  }
}

private actor SequencedAppleSignInService: AppleSignInPerforming {
  private var credentials: [AppleSignInCredential]

  init(credentials: [AppleSignInCredential]) {
    self.credentials = credentials
  }

  func signIn() async throws -> AppleSignInCredential {
    credentials.removeFirst()
  }

  func restoreSession(
    snapshot _: ProductAccountSessionSnapshot
  ) async throws -> AppleSignInCredential {
    credentials.removeFirst()
  }
}

private actor SequencedSuspendingAppleSignInService: AppleSignInPerforming {
  private var callIndex = 0
  private var credentials: [AppleSignInCredential]
  private let gate: BootstrapRestoreGate
  private let suspendedCallIndex: Int

  init(
    credentials: [AppleSignInCredential],
    suspendedCallIndex: Int,
    gate: BootstrapRestoreGate
  ) {
    self.credentials = credentials
    self.suspendedCallIndex = suspendedCallIndex
    self.gate = gate
  }

  func signIn() async throws -> AppleSignInCredential {
    guard !credentials.isEmpty else {
      throw ProductAccountSessionTestError.unexpectedAuthenticationRequest
    }
    let credential = credentials.removeFirst()
    defer { callIndex += 1 }
    if callIndex == suspendedCallIndex {
      await gate.waitForRelease()
    }
    return credential
  }

  func restoreSession(
    snapshot _: ProductAccountSessionSnapshot
  ) async throws -> AppleSignInCredential {
    try await signIn()
  }
}

private enum ProductAccountSessionTestError: Error {
  case gmailCleanupFailed
  case keyCleanupFailed
  case pushUnregistrationFailed
  case sessionClearFailed
  case sessionLoadFailed
  case sessionSaveFailed
  case trustedDeviceUnregistrationFailed
  case unexpectedAuthenticationRequest
}

private final class RecordingProductAccountService: ProductAccountConnecting {
  var materialInitializationIdentityTokens: [String] = []
  var recoveryBackedUp = true
  var recoveryCheckCount = 0
  var recoveryCheckExpectedWrappedAccountKeys: [ProductSyncEncryptedPayload?] = []
  var recoveryCheckIdentityTokens: [String] = []
  var recoveryMaterial: EncryptedProductSyncPayload?
  var recoveryMaterialIdentityTokens: [String] = []
  let response: ProductAccountConnectResponse
  var unregisterError: Error?
  var unregistrationAction: (() -> Void)?
  var unregistrationIdentityTokens: [String] = []
  var unregisteredTrustedDeviceIds: [String] = []

  init(response: ProductAccountConnectResponse) {
    self.response = response
  }

  func connect(identityToken _: String) async throws -> ProductAccountConnectResponse {
    response
  }

  func markProductSyncMaterialInitialized(
    identityToken: String,
    trustedDeviceId _: String
  ) async throws -> ProductSyncMaterialInitializedResponse {
    materialInitializationIdentityTokens.append(identityToken)
    return ProductSyncMaterialInitializedResponse(
      productSyncMaterialInitialized: true
    )
  }

  func productSyncRecoveryIsBackedUp(
    identityToken: String,
    expectedRecoveryWrappedAccountKey: ProductSyncEncryptedPayload?
  ) async throws -> Bool {
    recoveryCheckCount += 1
    recoveryCheckIdentityTokens.append(identityToken)
    recoveryCheckExpectedWrappedAccountKeys.append(expectedRecoveryWrappedAccountKey)
    return recoveryBackedUp
  }

  func productSyncRecoveryMaterial(
    identityToken: String
  ) async throws -> EncryptedProductSyncPayload? {
    recoveryMaterialIdentityTokens.append(identityToken)
    return recoveryMaterial
  }

  func unregisterTrustedDevice(
    identityToken: String,
    trustedDeviceId: String
  ) async throws -> TrustedDeviceUnregistrationResponse {
    unregistrationAction?()
    unregistrationIdentityTokens.append(identityToken)
    unregisteredTrustedDeviceIds.append(trustedDeviceId)
    if let unregisterError {
      throw unregisterError
    }
    return TrustedDeviceUnregistrationResponse(registered: false)
  }
}

private final class ControllableProductAccountSessionStore: ProductAccountSessionPersisting {
  var didClear = false
  var loadCount = 0
  var loadError: Error?
  var saveError: Error?
  var clearError: Error?
  var unacknowledgedRecoveryKeySaveError: Error?

  private var pendingSignOutProductAccountId: String?
  private var pendingTrustedDeviceUnregistrations: [String: PendingTrustedDeviceUnregistration] =
    [:]
  private var snapshot: ProductAccountSessionSnapshot?
  private var unacknowledgedRecoveryKeys: [String: UnacknowledgedRecoveryKey] = [:]

  init(snapshot: ProductAccountSessionSnapshot? = nil) {
    self.snapshot = snapshot
  }

  func load() throws -> ProductAccountSessionSnapshot? {
    loadCount += 1
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
    if let clearError {
      throw clearError
    }
    didClear = true
    snapshot = nil
  }

  func loadUnacknowledgedRecoveryKey(productAccountId: String) throws
    -> UnacknowledgedRecoveryKey?
  {
    unacknowledgedRecoveryKeys[productAccountId]
  }

  func saveUnacknowledgedRecoveryKey(
    _ recoveryKey: UnacknowledgedRecoveryKey,
    productAccountId: String
  ) throws {
    if let unacknowledgedRecoveryKeySaveError {
      throw unacknowledgedRecoveryKeySaveError
    }
    unacknowledgedRecoveryKeys[productAccountId] = recoveryKey
  }

  func clearUnacknowledgedRecoveryKey(productAccountId: String) throws {
    unacknowledgedRecoveryKeys[productAccountId] = nil
  }

  func loadPendingTrustedDeviceUnregistrations() throws
    -> [PendingTrustedDeviceUnregistration]
  {
    Array(pendingTrustedDeviceUnregistrations.values)
  }

  func savePendingTrustedDeviceUnregistration(
    _ unregistration: PendingTrustedDeviceUnregistration
  ) throws {
    pendingTrustedDeviceUnregistrations[unregistration.trustedDeviceId] = unregistration
  }

  func clearPendingTrustedDeviceUnregistration(trustedDeviceId: String) throws {
    pendingTrustedDeviceUnregistrations[trustedDeviceId] = nil
  }

  func loadPendingSignOutProductAccountId() throws -> String? {
    pendingSignOutProductAccountId
  }

  func savePendingSignOutProductAccountId(_ productAccountId: String) throws {
    pendingSignOutProductAccountId = productAccountId
  }

  func clearPendingSignOutProductAccountId() throws {
    pendingSignOutProductAccountId = nil
  }
}

private final class RecordingGmailProviderConnecting:
  GmailProviderConnecting, MailboxConnectionClearing
{
  var clearedSession: ProductAccountSessionSnapshot?
  var clearedSessions: [ProductAccountSessionSnapshot] = []
  var clearAction: (() -> Void)?
  var clearError: Error?

  func clearLocalConnection(
    session: ProductAccountSessionSnapshot
  ) async throws {
    clearedSession = session
    clearedSessions.append(session)
    clearAction?()
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
  var action: (() -> Void)?
  var error: Error?
  var sessions: [ProductAccountSessionSnapshot] = []

  func unregister(session: ProductAccountSessionSnapshot) async throws {
    sessions.append(session)
    action?()
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

private struct AuthenticationPresentationFixture: @unchecked Sendable {
  let appleProvider: ASAuthorizationControllerPresentationContextProviding
  let authenticationWindow: ASPresentationAnchor
  let webProviders: [ASWebAuthenticationPresentationContextProviding]
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
