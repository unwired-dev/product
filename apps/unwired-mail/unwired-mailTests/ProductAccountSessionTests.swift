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
            appleUserIdentifier: "apple-user-002",
            identityToken: "token-002"
          )
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
    XCTAssertEqual(
      try store.loadPendingTrustedDeviceUnregistrations(),
      [
        PendingTrustedDeviceUnregistration(
          appleUserIdentifier: oldSnapshot.appleUserIdentifier,
          productAccountId: oldSnapshot.productAccountId,
          trustedDeviceId: oldSnapshot.trustedDeviceId
        )
      ]
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

  func testProductAccountDeletionRequiresRecentMatchingAppleAuthenticationAndPurgesLocalData()
    async throws
  {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    try store.savePendingTrustedDeviceUnregistration(
      PendingTrustedDeviceUnregistration(
        appleUserIdentifier: snapshot.appleUserIdentifier,
        productAccountId: snapshot.productAccountId,
        trustedDeviceId: "stale-trusted-device"
      )
    )
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: snapshot.productAccountId,
      allowCreation: true
    )
    let mailboxConnectionService = RecordingGmailProviderConnecting()
    let outboxCleaner = RecordingOutboxDeliveryCleaner()
    let productSyncCacheClearer = RecordingProductSyncCacheClearer()
    let accountService = RecordingDeletionProductAccountService(response: Self.restorableResponse)
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          authorizationCode: "recent-authorization-code",
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      productAccountService: accountService,
      sessionStore: store,
      mailboxConnectionService: mailboxConnectionService,
      outboxDeliveryService: outboxCleaner,
      productSyncCacheClearer: productSyncCacheClearer,
      productSyncKeyMaterialStore: keyMaterialStore
    )
    await session.bootstrap()
    let mailActionViewModel = session.sharedMailActionViewModel(
      for: snapshot,
      service: MailboxConnectionRouter()
    )

    await session.deleteProductAccount()

    XCTAssertEqual(session.state, .signedOut)
    XCTAssertEqual(accountService.deletionAuthorizationCodes, ["recent-authorization-code"])
    XCTAssertEqual(accountService.deletionTrustedDeviceIds, [snapshot.trustedDeviceId])
    XCTAssertEqual(mailboxConnectionService.clearedSessions, [snapshot])
    XCTAssertEqual(outboxCleaner.clearedSessions, [snapshot])
    XCTAssertNil(try store.load())
    XCTAssertNil(try keyMaterialStore.load(productAccountId: snapshot.productAccountId))
    XCTAssertEqual(productSyncCacheClearer.clearedProductAccountIds, [snapshot.productAccountId])
    XCTAssertTrue(mailActionViewModel.isPreparingForSignOut)
    XCTAssertEqual(try store.loadPendingTrustedDeviceUnregistrations(), [])
  }

  func testProductAccountDeletionBlocksMailActionsWhileBackendDeletionRuns() async throws {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: snapshot.productAccountId,
      allowCreation: true
    )
    let accountService = RecordingDeletionProductAccountService(response: Self.restorableResponse)
    accountService.deletionError = ProductAccountSessionTestError.sessionClearFailed
    let mailboxConnectionService = RecordingGmailProviderConnecting()
    let outboxCleaner = RecordingOutboxDeliveryCleaner()
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          authorizationCode: "recent-authorization-code",
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      productAccountService: accountService,
      sessionStore: store,
      mailboxConnectionService: mailboxConnectionService,
      outboxDeliveryService: outboxCleaner,
      productSyncKeyMaterialStore: keyMaterialStore
    )
    await session.bootstrap()
    let mailActionService = RecordingDeletionMailActionService()
    let mailActionViewModel = session.sharedMailActionViewModel(
      for: snapshot,
      service: mailActionService
    )

    accountService.deletionAction = {
      XCTAssertTrue(mailActionViewModel.isPreparingForSignOut)
    }

    await session.deleteProductAccount()
    XCTAssertEqual(session.state, .signedIn(snapshot))
    XCTAssertFalse(mailActionViewModel.isPreparingForSignOut)
    XCTAssertEqual(mailActionService.resumePendingActionsCallCount, 1)
  }

  func testProductAccountDeletionRollsBackWhenReconnectReturnsAnotherAccount() async throws {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: snapshot.productAccountId,
      allowCreation: true
    )
    let accountService = RecordingDeletionProductAccountService(response: Self.restorableResponse)
    accountService.deletionError = ProductAccountSessionTestError.sessionClearFailed
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          authorizationCode: "recent-authorization-code",
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      productAccountService: accountService,
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore
    )
    await session.bootstrap()
    let mailActionService = RecordingDeletionMailActionService()
    let mailActionViewModel = session.sharedMailActionViewModel(
      for: snapshot,
      service: mailActionService
    )
    accountService.response = ProductAccountConnectResponse(
      accountCreated: false,
      deviceRegistered: true,
      productSyncMaterialInitialized: true,
      productAccountId: "another-product-account",
      trustedDeviceId: "another-trusted-device"
    )

    await session.deleteProductAccount()

    XCTAssertEqual(session.state, .signedIn(snapshot))
    XCTAssertFalse(mailActionViewModel.isPreparingForSignOut)
    XCTAssertEqual(mailActionService.resumePendingActionsCallCount, 1)
    XCTAssertEqual(
      session.deletionErrorMessage,
      ProductAccountSessionError.differentAppleAccount.localizedDescription
    )
  }

  func testProductAccountDeletionRollsBackWhenReconnectFails() async throws {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: snapshot.productAccountId,
      allowCreation: true
    )
    let accountService = RecordingDeletionProductAccountService(response: Self.restorableResponse)
    accountService.deletionError = ProductAccountSessionTestError.sessionClearFailed
    accountService.connectError = ProductAccountSessionTestError.sessionLoadFailed
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          authorizationCode: "recent-authorization-code",
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      productAccountService: accountService,
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore
    )
    await session.bootstrap()
    let mailActionService = RecordingDeletionMailActionService()
    let mailActionViewModel = session.sharedMailActionViewModel(
      for: snapshot,
      service: mailActionService
    )

    await session.deleteProductAccount()

    XCTAssertEqual(session.state, .signedIn(snapshot))
    XCTAssertFalse(mailActionViewModel.isPreparingForSignOut)
    XCTAssertEqual(mailActionService.resumePendingActionsCallCount, 1)
    XCTAssertEqual(
      session.deletionErrorMessage,
      ProductAccountSessionTestError.sessionClearFailed.localizedDescription
    )
  }

  func testProductAccountMailboxConnectionIdLoaderCombinesPartialSnapshotWithLocalIds()
    async throws
  {
    let localConnectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .gmail,
        value: "local-account"
      )
    )
    let loader = ProductAccountMailboxConnectionIdLoader(
      snapshotLoader: StubMailboxConnectionSnapshotLoader(
        snapshot: MailboxConnectionLoadSnapshot(
          connections: [],
          isAuthoritative: false,
          loadErrorDescription: "provider unavailable"
        )
      ),
      deviceLocalLoader: StubMailboxConnectionIdLoader(connectionIds: [localConnectionId])
    )

    let connectionIds = try await loader.loadConnectionIds(session: Self.restorableSnapshot)

    XCTAssertEqual(connectionIds, [localConnectionId])
  }

  func testProductAccountMailboxConnectionIdLoaderUsesSnapshotWhenLocalLoadingFails()
    async throws
  {
    let snapshotConnectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .gmail,
        value: "snapshot-account"
      )
    )
    let loader = ProductAccountMailboxConnectionIdLoader(
      snapshotLoader: StubMailboxConnectionSnapshotLoader(
        snapshot: MailboxConnectionLoadSnapshot(
          connections: [
            MailboxConnection(
              authorizationState: .authorized,
              capabilities: .gmail,
              connectedAt: 1,
              displayName: "snapshot@example.com",
              id: snapshotConnectionId,
              lastVerifiedAt: 2,
              productAccountId: ProductAccountId(Self.restorableSnapshot.productAccountId),
              trustedDeviceId: Self.restorableSnapshot.trustedDeviceId,
              updatedAt: 3
            )
          ],
          isAuthoritative: true,
          loadErrorDescription: nil
        )
      ),
      deviceLocalLoader: StubMailboxConnectionIdLoader(
        connectionIds: [],
        error: ProductAccountSessionTestError.sessionLoadFailed
      )
    )

    let connectionIds = try await loader.loadConnectionIds(session: Self.restorableSnapshot)

    XCTAssertEqual(connectionIds, [snapshotConnectionId])
  }

  func testProductAccountMailboxConnectionIdLoaderPropagatesLocalLoadingCancellation() async {
    let loader = ProductAccountMailboxConnectionIdLoader(
      snapshotLoader: StubMailboxConnectionSnapshotLoader(
        snapshot: MailboxConnectionLoadSnapshot(
          connections: [],
          isAuthoritative: true,
          loadErrorDescription: nil
        )
      ),
      deviceLocalLoader: StubMailboxConnectionIdLoader(
        connectionIds: [],
        error: CancellationError()
      )
    )

    do {
      _ = try await loader.loadConnectionIds(session: Self.restorableSnapshot)
      XCTFail("Expected cancellation")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
  }

  func testProductAccountDeletionRemovesOnlyItsRemoteContentOverrides() async throws {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: snapshot.productAccountId,
      allowCreation: true
    )
    let suiteName = "ProductAccountDeletionPrivacy.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let deletedConnectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .gmail,
        value: "deleted@example.com"
      )
    )
    let retainedConnectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .gmail,
        value: "retained@example.com"
      )
    )
    let preferences = MessageContentPreferences(defaults: defaults)
    preferences.setRemoteContentOverride(.never, for: deletedConnectionId)
    preferences.setRemoteContentOverride(.alwaysLoad, for: retainedConnectionId)
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          authorizationCode: "recent-authorization-code",
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      productAccountService: RecordingDeletionProductAccountService(
        response: Self.restorableResponse
      ),
      sessionStore: store,
      mailboxConnectionService: RecordingGmailProviderConnecting(),
      mailboxConnectionIdLoader: StubMailboxConnectionIdLoader(
        connectionIds: [deletedConnectionId]
      ),
      messageContentPreferences: preferences,
      productSyncKeyMaterialStore: keyMaterialStore
    )
    await session.bootstrap()

    await session.deleteProductAccount()

    XCTAssertNil(preferences.remoteContentOverride(for: deletedConnectionId))
    XCTAssertEqual(preferences.remoteContentOverride(for: retainedConnectionId), .alwaysLoad)
  }

  func testProductAccountDeletionContinuesWhenPrivacyIdLookupFails() async throws {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: snapshot.productAccountId,
      allowCreation: true
    )
    let mailboxConnectionService = RecordingGmailProviderConnecting()
    let notificationClearer = RecordingNotificationClearer()
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          authorizationCode: "recent-authorization-code",
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      notificationClearer: notificationClearer,
      productAccountService: RecordingDeletionProductAccountService(
        response: Self.restorableResponse
      ),
      sessionStore: store,
      mailboxConnectionService: mailboxConnectionService,
      mailboxConnectionIdLoader: StubMailboxConnectionIdLoader(
        connectionIds: [],
        error: ProductAccountSessionTestError.sessionLoadFailed
      ),
      productSyncKeyMaterialStore: keyMaterialStore
    )
    await session.bootstrap()

    await session.deleteProductAccount()

    XCTAssertEqual(session.state, .signedOut)
    XCTAssertEqual(mailboxConnectionService.clearedSessions, [snapshot])
    XCTAssertEqual(notificationClearer.clearedProductAccountIds, [snapshot.productAccountId])
  }

  func testProductAccountDeletionPurgesLocalDataWhenFailureRevalidationFindsTombstone()
    async throws
  {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: snapshot.productAccountId,
      allowCreation: true
    )
    let accountService = RecordingDeletionProductAccountService(response: Self.restorableResponse)
    accountService.deletionError = ProductAccountSessionTestError.sessionClearFailed
    let mailboxConnectionService = RecordingGmailProviderConnecting()
    let outboxCleaner = RecordingOutboxDeliveryCleaner()
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          authorizationCode: "recent-authorization-code",
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      productAccountService: accountService,
      sessionStore: store,
      mailboxConnectionService: mailboxConnectionService,
      outboxDeliveryService: outboxCleaner,
      productSyncKeyMaterialStore: keyMaterialStore
    )
    await session.bootstrap()
    accountService.connectError = ProductAccountServiceError.productAccountDeleted

    await session.deleteProductAccount()

    XCTAssertEqual(session.state, .signedOut)
    XCTAssertNil(try store.load())
    XCTAssertNil(try keyMaterialStore.load(productAccountId: snapshot.productAccountId))
    XCTAssertEqual(mailboxConnectionService.clearedSessions, [snapshot])
    XCTAssertEqual(outboxCleaner.clearedSessions, [snapshot])
    XCTAssertNil(session.deletionErrorMessage)
  }

  func testProductAccountDeletionClearsSessionAfterBackgroundCleanupStarts() async throws {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: snapshot.productAccountId,
      allowCreation: true
    )
    let accountService = RecordingDeletionProductAccountService(response: Self.restorableResponse)
    accountService.deletionResponse = ProductAccountDeletionResponse(deleted: false)
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          authorizationCode: "recent-authorization-code",
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      productAccountService: accountService,
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore
    )
    await session.bootstrap()

    await session.deleteProductAccount()

    XCTAssertEqual(session.state, .signedOut)
    XCTAssertNil(try store.load())
    XCTAssertEqual(accountService.deletionAuthorizationCodes, ["recent-authorization-code"])
    XCTAssertNil(session.deletionErrorMessage)
  }

  func testProductAccountDeletionLeavesTombstonedSessionOutOfSignedInStateWhenCleanupFails()
    async throws
  {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: snapshot.productAccountId,
      allowCreation: true
    )
    let outboxCleaner = RecordingOutboxDeliveryCleaner()
    outboxCleaner.clearError = ProductAccountSessionTestError.outboxCleanupFailed
    let pushWakeupDrainer = RecordingGmailPushWakeupDrainer()
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          authorizationCode: "recent-authorization-code",
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      gmailPushWakeupDrainer: pushWakeupDrainer,
      productAccountService: RecordingDeletionProductAccountService(
        response: Self.restorableResponse
      ),
      sessionStore: store,
      outboxDeliveryService: outboxCleaner,
      productSyncKeyMaterialStore: keyMaterialStore
    )
    await session.bootstrap()

    await session.deleteProductAccount()

    XCTAssertEqual(
      session.state,
      .failed(ProductAccountSessionTestError.outboxCleanupFailed.localizedDescription)
    )
    XCTAssertEqual(try store.loadPendingDeletedProductAccountId(), snapshot.productAccountId)
    XCTAssertEqual(pushWakeupDrainer.drainedProductAccountIds, [snapshot.productAccountId])
    XCTAssertEqual(pushWakeupDrainer.finishedProductAccountIds, [snapshot.productAccountId])
  }

  func testProductAccountDeletionKeepsLocalDataWhenRecentAppleAccountDoesNotMatch()
    async throws
  {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: snapshot.productAccountId,
      allowCreation: true
    )
    let mailboxConnectionService = RecordingGmailProviderConnecting()
    let accountService = RecordingDeletionProductAccountService(response: Self.restorableResponse)
    let session = ProductAccountSession(
      appleSignInService: SequencedAppleSignInService(
        credentials: [
          AppleSignInCredential(
            appleUserIdentifier: snapshot.appleUserIdentifier,
            identityToken: snapshot.identityToken
          ),
          AppleSignInCredential(
            authorizationCode: "other-authorization-code",
            appleUserIdentifier: "another-apple-user",
            identityToken: "other-identity-token"
          ),
        ]
      ),
      productAccountService: accountService,
      sessionStore: store,
      mailboxConnectionService: mailboxConnectionService,
      productSyncKeyMaterialStore: keyMaterialStore
    )
    await session.bootstrap()

    await session.deleteProductAccount()

    XCTAssertEqual(try store.load(), snapshot)
    XCTAssertEqual(accountService.deletionAuthorizationCodes, [])
    XCTAssertEqual(mailboxConnectionService.clearedSessions, [])
    XCTAssertEqual(
      session.deletionErrorMessage,
      ProductAccountSessionError.differentAppleAccount.localizedDescription
    )
  }

  func testReachableDevicePurgesLocalDataWhenBackendReportsDeletedProductAccount() async throws {
    let snapshot = Self.restorableSnapshot
    let freshnessKey = "mailbox-sync-success.\(snapshot.productAccountId).gmail:account-001"
    UserDefaults.standard.set(Date(), forKey: freshnessKey)
    defer { UserDefaults.standard.removeObject(forKey: freshnessKey) }
    try store.save(snapshot)
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: snapshot.productAccountId,
      allowCreation: true
    )
    let mailboxConnectionService = RecordingGmailProviderConnecting()
    let pushWakeupDrainer = RecordingGmailPushWakeupDrainer()
    let accountService = RecordingDeletionProductAccountService(response: Self.restorableResponse)
    var stateDuringCleanup: ProductAccountSessionState?
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      gmailPushWakeupDrainer: pushWakeupDrainer,
      productAccountService: accountService,
      sessionStore: store,
      mailboxConnectionService: mailboxConnectionService,
      productSyncKeyMaterialStore: keyMaterialStore
    )
    pushWakeupDrainer.drainAction = {
      XCTAssertNotNil(UserDefaults.standard.object(forKey: freshnessKey))
    }
    mailboxConnectionService.clearAction = {
      stateDuringCleanup = session.state
    }
    await session.bootstrap()
    accountService.connectError = ProductAccountServiceError.productAccountDeleted

    await session.revalidateProductAccountAfterForegrounding()

    XCTAssertEqual(session.state, .signedOut)
    XCTAssertNil(try store.load())
    XCTAssertNil(try keyMaterialStore.load(productAccountId: snapshot.productAccountId))
    XCTAssertEqual(mailboxConnectionService.clearedSessions, [snapshot])
    XCTAssertEqual(pushWakeupDrainer.drainedProductAccountIds, [snapshot.productAccountId])
    XCTAssertEqual(stateDuringCleanup, .loading)
    XCTAssertNil(UserDefaults.standard.object(forKey: freshnessKey))
  }

  // swiftlint:disable:next function_body_length
  func testForegroundRevalidationUsesNoninteractiveAuthentication() async throws {
    let snapshot = ProductAccountSessionSnapshot(
      appleUserIdentifier: Self.restorableSnapshot.appleUserIdentifier,
      identityToken: "expired-token",
      identityTokenExpiresAt: .distantPast,
      productAccountId: Self.restorableSnapshot.productAccountId,
      trustedDeviceId: Self.restorableSnapshot.trustedDeviceId
    )
    try store.save(snapshot)
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: snapshot.productAccountId,
      allowCreation: true
    )
    let appleSignInService = SequencedAppleSignInService(
      credentials: [
        AppleSignInCredential(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: "expired-token"
        ),
        AppleSignInCredential(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: "fresh-token"
        ),
      ]
    )
    let session = ProductAccountSession(
      appleSignInService: appleSignInService,
      productAccountService: RecordingDeletionProductAccountService(
        response: Self.restorableResponse
      ),
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore
    )
    let staleFreshnessViewModel = session.sharedMailboxFreshnessViewModel(
      for: snapshot,
      service: MailboxConnectionRouter()
    )

    await session.bootstrap()
    await session.revalidateProductAccountAfterForegrounding()

    guard case .signedIn(let refreshedSnapshot) = session.state else {
      return XCTFail("Expected signed-in state")
    }
    XCTAssertEqual(refreshedSnapshot.identityToken, "fresh-token")
    XCTAssertEqual(try store.load(), refreshedSnapshot)
    let refreshedFreshnessViewModel = session.sharedMailboxFreshnessViewModel(
      for: refreshedSnapshot,
      service: MailboxConnectionRouter()
    )
    XCTAssertFalse(staleFreshnessViewModel === refreshedFreshnessViewModel)
    let signInCallCount = await appleSignInService.signInCallCount
    let restoreSessionCallCount = await appleSignInService.restoreSessionCallCount
    XCTAssertEqual(signInCallCount, 0)
    XCTAssertEqual(restoreSessionCallCount, 2)
  }

  func testForegroundRevalidationPurgesLocalDataWhenAppleAuthorizationIsRevoked() async throws {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: snapshot.productAccountId,
      allowCreation: true
    )
    let mailboxConnectionService = RecordingGmailProviderConnecting()
    let outboxCleaner = RecordingOutboxDeliveryCleaner()
    let session = ProductAccountSession(
      appleSignInService: RevokedOnSecondRestoreSignInService(),
      productAccountService: PreviewProductAccountService(response: Self.restorableResponse),
      sessionStore: store,
      mailboxConnectionService: mailboxConnectionService,
      outboxDeliveryService: outboxCleaner,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.bootstrap()
    let mailActionViewModel = session.sharedMailActionViewModel(
      for: snapshot,
      service: MailboxConnectionRouter()
    )
    await session.revalidateProductAccountAfterForegrounding()

    XCTAssertEqual(session.state, .signedOut)
    XCTAssertNil(try store.load())
    XCTAssertNil(try keyMaterialStore.load(productAccountId: snapshot.productAccountId))
    XCTAssertEqual(mailboxConnectionService.clearedSessions, [snapshot])
    XCTAssertEqual(outboxCleaner.clearedSessions, [snapshot])
    XCTAssertTrue(mailActionViewModel.isPreparingForSignOut)
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

  func testMailActionViewModelIsSharedAcrossSessionViews() {
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: "apple-user-001",
          identityToken: "token-001"
        )
      ),
      sessionStore: store
    )

    let mailViewModel = session.sharedMailActionViewModel(
      for: Self.restorableSnapshot,
      service: MailboxConnectionRouter()
    )
    let settingsViewModel = session.sharedMailActionViewModel(
      for: Self.restorableSnapshot,
      service: MailboxConnectionRouter()
    )

    XCTAssertTrue(mailViewModel === settingsViewModel)
  }

  func testReplacingMailActionViewModelRetiresThePreviousSession() {
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: "apple-user-001",
          identityToken: "token-001"
        )
      ),
      sessionStore: store
    )
    let previousViewModel = session.sharedMailActionViewModel(
      for: Self.restorableSnapshot,
      service: MailboxConnectionRouter()
    )
    let replacementSnapshot = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-002",
      identityToken: "token-002",
      productAccountId: "product-account-002",
      trustedDeviceId: "trusted-device-002"
    )

    let replacementViewModel = session.sharedMailActionViewModel(
      for: replacementSnapshot,
      service: MailboxConnectionRouter()
    )

    XCTAssertFalse(previousViewModel === replacementViewModel)
    XCTAssertTrue(previousViewModel.isPreparingForSignOut)
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

  func testAppleAuthorizationCodeIsOptionalOutsideAccountDeletion() {
    XCTAssertNil(SignInWithAppleService.decodedAuthorizationCode(from: nil))
    XCTAssertEqual(
      SignInWithAppleService.decodedAuthorizationCode(from: Data("code".utf8)),
      "code"
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

  private static let restorableResponse = ProductAccountConnectResponse(
    accountCreated: false,
    deviceRegistered: true,
    productSyncMaterialInitialized: true,
    productAccountId: restorableSnapshot.productAccountId,
    trustedDeviceId: restorableSnapshot.trustedDeviceId
  )

  func testSignOutClearsStoredSession() async {
    let gmailConnectionService = RecordingGmailProviderConnecting()
    let outboxCleaner = RecordingOutboxDeliveryCleaner()
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
      outboxDeliveryService: outboxCleaner,
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
    XCTAssertEqual(
      outboxCleaner.clearedSessions.map(\.productAccountId),
      [ProductAccountConnectResponse.preview.productAccountId]
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
    let outboxCleaner = RecordingOutboxDeliveryCleaner()
    let productAccountService = RecordingProductAccountService(response: .preview)
    productAccountService.recoveryBackedUp = false
    productAccountService.recoveryCheckAction = {
      XCTAssertEqual(outboxCleaner.suspendedProductAccountIds, [snapshot.productAccountId])
    }
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
      outboxDeliveryService: outboxCleaner,
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

  func testRecoveryKeyPersistenceFailureDoesNotPopulateInMemoryMarker() async throws {
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
    guard case .signedIn = session.state else {
      return XCTFail("Expected bootstrap to restore the Product Account")
    }
    failingStore.unacknowledgedRecoveryKeySaveError =
      ProductAccountSessionTestError.sessionSaveFailed

    XCTAssertThrowsError(try session.preserveUnacknowledgedRecoveryKey("published-key"))

    XCTAssertNil(session.unacknowledgedRecoveryKey)
    XCTAssertNil(
      try failingStore.loadUnacknowledgedRecoveryKey(productAccountId: snapshot.productAccountId)
    )
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
    let outboxCleaner = RecordingOutboxDeliveryCleaner()
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
      outboxDeliveryService: outboxCleaner,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    let signOut = Task { await session.signOut() }
    await cleanupGate.waitUntilStarted()

    XCTAssertEqual(session.state, .loading)
    XCTAssertEqual(outboxCleaner.clearedSessions, [snapshot])

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
    let mailActionViewModel = session.sharedMailActionViewModel(
      for: snapshot,
      service: MailboxConnectionRouter()
    )

    session.beginSignOut()

    XCTAssertEqual(session.state, .loading)
    XCTAssertFalse(session.isCurrent(snapshot))
    XCTAssertTrue(mailActionViewModel.isPreparingForSignOut)
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

  func testSignOutPreservesStoredSessionWhenOutboxCleanupFails() async throws {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    let mailboxConnectionService = RecordingGmailProviderConnecting()
    let outboxCleaner = RecordingOutboxDeliveryCleaner()
    outboxCleaner.clearError = ProductAccountSessionTestError.outboxCleanupFailed
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
      sessionStore: store,
      mailboxConnectionService: mailboxConnectionService,
      outboxDeliveryService: outboxCleaner,
      productSyncKeyMaterialStore: keyMaterialStore
    )
    let mailActionViewModel = session.sharedMailActionViewModel(
      for: snapshot,
      service: MailboxConnectionRouter()
    )

    await session.signOut()

    XCTAssertEqual(session.state, .signedIn(snapshot))
    XCTAssertEqual(
      session.signOutErrorMessage,
      ProductAccountSessionTestError.outboxCleanupFailed.localizedDescription
    )
    XCTAssertEqual(try store.load(), snapshot)
    XCTAssertNil(try store.loadPendingSignOutProductAccountId())
    XCTAssertEqual(outboxCleaner.clearedSessions, [snapshot])
    XCTAssertTrue(mailboxConnectionService.clearedSessions.isEmpty)
    XCTAssertTrue(productAccountService.unregisteredTrustedDeviceIds.isEmpty)
    XCTAssertFalse(mailActionViewModel.isPreparingForSignOut)
    XCTAssertTrue(
      mailActionViewModel
        === session.sharedMailActionViewModel(
          for: snapshot,
          service: MailboxConnectionRouter()
        )
    )
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
    let outboxCleaner = RecordingOutboxDeliveryCleaner()
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: store,
      outboxDeliveryService: outboxCleaner,
      productSyncKeyMaterialStore: keyMaterialStore
    )
    var pendingAccountIdDuringPreparation: String?
    var clearedOutboxDuringPreparation = false

    await session.signOut {
      pendingAccountIdDuringPreparation = try? self.store.loadPendingSignOutProductAccountId()
      clearedOutboxDuringPreparation = outboxCleaner.clearedSessions == [snapshot]
    }

    XCTAssertEqual(pendingAccountIdDuringPreparation, snapshot.productAccountId)
    XCTAssertTrue(clearedOutboxDuringPreparation)
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
    let outboxCleaner = RecordingOutboxDeliveryCleaner()
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
      outboxDeliveryService: outboxCleaner,
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
    XCTAssertEqual(outboxCleaner.clearedSessions, [snapshot])
    XCTAssertEqual(productAccountService.unregisteredTrustedDeviceIds, [snapshot.trustedDeviceId])
  }

  func testBootstrapDropsTrustedDeviceRetryWhenInterruptedDeletionAlreadyCompleted() async throws {
    let snapshot = ProductAccountSessionSnapshot(
      appleUserIdentifier: Self.restorableSnapshot.appleUserIdentifier,
      identityToken: "active-token",
      identityTokenExpiresAt: .distantFuture,
      productAccountId: Self.restorableSnapshot.productAccountId,
      trustedDeviceId: Self.restorableSnapshot.trustedDeviceId
    )
    let sessionStore = ControllableProductAccountSessionStore(snapshot: snapshot)
    try sessionStore.savePendingDeletedProductAccountId(snapshot.productAccountId)
    try sessionStore.savePendingSignOutProductAccountId(snapshot.productAccountId)
    try sessionStore.savePendingTrustedDeviceUnregistration(
      PendingTrustedDeviceUnregistration(
        appleUserIdentifier: snapshot.appleUserIdentifier,
        productAccountId: snapshot.productAccountId,
        trustedDeviceId: snapshot.trustedDeviceId
      )
    )
    let productAccountService = RecordingProductAccountService(response: .preview)
    productAccountService.unregisterError = ProductAccountServiceError.productAccountDeleted
    let mailboxConnectionService = RecordingGmailProviderConnecting()
    let outboxCleaner = RecordingOutboxDeliveryCleaner()
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      productAccountService: productAccountService,
      sessionStore: sessionStore,
      mailboxConnectionService: mailboxConnectionService,
      outboxDeliveryService: outboxCleaner,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.bootstrap()

    XCTAssertEqual(session.state, .signedOut)
    XCTAssertTrue(try sessionStore.loadPendingTrustedDeviceUnregistrations().isEmpty)
    XCTAssertNil(try sessionStore.loadPendingSignOutProductAccountId())
    XCTAssertNil(try sessionStore.loadPendingDeletedProductAccountId())
    XCTAssertTrue(productAccountService.unregisteredTrustedDeviceIds.isEmpty)
    XCTAssertEqual(mailboxConnectionService.clearedSessions, [snapshot])
    XCTAssertEqual(outboxCleaner.clearedSessions, [snapshot])
  }

  func testBootstrapDoesNotPersistUnregistrationRetryForInterruptedDeletedAccount()
    async throws
  {
    let snapshot = ProductAccountSessionSnapshot(
      appleUserIdentifier: Self.restorableSnapshot.appleUserIdentifier,
      identityToken: "expired-token",
      identityTokenExpiresAt: .distantPast,
      productAccountId: Self.restorableSnapshot.productAccountId,
      trustedDeviceId: Self.restorableSnapshot.trustedDeviceId
    )
    let sessionStore = ControllableProductAccountSessionStore(snapshot: snapshot)
    try sessionStore.savePendingDeletedProductAccountId(snapshot.productAccountId)
    try sessionStore.savePendingSignOutProductAccountId(snapshot.productAccountId)
    let productAccountService = RecordingProductAccountService(response: .preview)
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      productAccountService: productAccountService,
      sessionStore: sessionStore,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.bootstrap()

    XCTAssertEqual(session.state, .signedOut)
    XCTAssertTrue(try sessionStore.loadPendingTrustedDeviceUnregistrations().isEmpty)
    XCTAssertNil(try sessionStore.loadPendingDeletedProductAccountId())
    XCTAssertTrue(productAccountService.unregisteredTrustedDeviceIds.isEmpty)
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

  func testFileOutboxStoreScopesAttemptsAndClearByProductAccount() throws {
    func attempt(productAccountId: String) -> OutgoingDeliveryAttempt {
      OutgoingDeliveryAttempt(
        attemptCount: 0,
        connectionId: MailboxConnectionId(
          providerMailboxIdentity: StableProviderMailboxIdentity(
            providerId: .gmail,
            value: "gmail-user-001"
          )
        ),
        createdAtMilliseconds: 1_700_000_000_000,
        firstAttemptAtMilliseconds: nil,
        id: UUID(),
        idempotencyKey: UUID().uuidString,
        lastErrorDescription: nil,
        message: OutgoingMessage(
          body: "Queued private body",
          recipient: "reader@example.com",
          subject: "Queued message"
        ),
        nextRetryAtMilliseconds: nil,
        productAccountId: ProductAccountId(productAccountId),
        reconciliationAttemptCount: 0,
        state: .pending
      )
    }

    let rootDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("product-account-outbox-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(
      productAccountId: "product-account-001",
      allowCreation: true
    )
    _ = try keyStore.ensureMaterial(
      productAccountId: "product-account-002",
      allowCreation: true
    )
    let store = FileOutboxDeliveryStore(
      keyMaterialStore: keyStore,
      rootDirectory: rootDirectory
    )
    let firstAttempt = attempt(productAccountId: "product-account-001")
    let secondAttempt = attempt(productAccountId: "product-account-002")
    try store.save([firstAttempt], productAccountId: "product-account-001")
    try store.save([secondAttempt], productAccountId: "product-account-002")

    XCTAssertEqual(try store.load(productAccountId: "product-account-001"), [firstAttempt])
    XCTAssertEqual(try store.load(productAccountId: "product-account-002"), [secondAttempt])

    try store.clear(productAccountId: "product-account-001")

    XCTAssertEqual(try store.load(productAccountId: "product-account-001"), [])
    XCTAssertEqual(try store.load(productAccountId: "product-account-002"), [secondAttempt])
  }

  // swiftlint:disable:next function_body_length
  func testSignOutPresentsOutboxCleanupFailureAndPreservesStoredSession() async throws {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    let connection = GmailProviderConnectionStatus(
      connectedAt: 1_700_000_000_000,
      emailAddress: "reader@example.com",
      lastVerifiedAt: 1_700_000_000_000,
      provider: "gmail",
      providerAccountIdentifier: "gmail-user-001",
      trustedDeviceId: snapshot.trustedDeviceId,
      updatedAt: 1_700_000_000_000
    ).mailboxConnection(
      productAccountId: snapshot.productAccountId,
      authorizationState: .authorized
    )
    let outboxStore = ProductAccountOutboxStore()
    let outboxService = OutboxDeliveryService(
      handoffDelayNanoseconds: 60_000_000_000,
      store: outboxStore
    )
    _ = try await outboxService.enqueue(
      OutgoingMessage(
        body: "Queued private body",
        recipient: "reader@example.com",
        subject: "Queued message"
      ),
      connection: connection,
      session: snapshot,
      provider: { _, _, _ in },
      reconcile: { _, _ in .notSent }
    )
    outboxStore.clearError = ProductAccountSessionTestError.outboxCleanupFailed
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
      mailboxConnectionService: GmailMailboxConnectionAdapter(
        connectionService: RecordingGmailProviderConnecting(),
        pendingActionService: PendingProviderActionService(
          store: EmptyProductAccountPendingActionStore()
        ),
        outboxService: outboxService
      ),
      outboxDeliveryService: outboxService,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.signOut()

    XCTAssertEqual(
      session.state,
      .signedIn(snapshot)
    )
    XCTAssertEqual(
      session.signOutErrorMessage,
      ProductAccountSessionTestError.outboxCleanupFailed.localizedDescription
    )
    XCTAssertEqual(try store.load(), snapshot)
    XCTAssertNil(try store.loadPendingSignOutProductAccountId())
    let retainedAttempts = try await outboxService.items(session: snapshot)
    XCTAssertEqual(retainedAttempts.map(\.message.body), ["Queued private body"])

    outboxStore.clearError = nil
    await session.signOut()

    XCTAssertEqual(session.state, .signedOut)
    XCTAssertNil(try store.load())
    let remainingAttempts = try await outboxService.items(session: snapshot)
    XCTAssertTrue(remainingAttempts.isEmpty)
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
    let outboxCleaner = RecordingOutboxDeliveryCleaner()
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
      outboxDeliveryService: outboxCleaner,
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
    XCTAssertEqual(outboxCleaner.suspendedProductAccountIds, [oldSnapshot.productAccountId])
    XCTAssertEqual(outboxCleaner.clearedSessions, [oldSnapshot])
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
    let outboxCleaner = RecordingOutboxDeliveryCleaner()
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
      outboxDeliveryService: outboxCleaner,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.signInWithApple()

    guard case .failed = session.state else {
      return XCTFail("Expected failed state")
    }
    XCTAssertEqual(try store.load(), oldSnapshot)
    XCTAssertEqual(gmailConnectionService.clearedSessions, [oldSnapshot])
    XCTAssertEqual(outboxCleaner.suspendedProductAccountIds, [oldSnapshot.productAccountId])
    XCTAssertTrue(outboxCleaner.clearedSessions.isEmpty)
    XCTAssertEqual(pushUnregisterer.sessions, [])
  }

  func testSignInRetainsOutboxCleanupWhenSessionRollbackFails() async throws {
    let oldSnapshot = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "old-token",
      productAccountId: "oldProductAccountId",
      trustedDeviceId: "oldTrustedDeviceId"
    )
    let sessionStore = ControllableProductAccountSessionStore(snapshot: oldSnapshot)
    sessionStore.saveErrorOnCall = 2
    let gmailConnectionService = RecordingGmailProviderConnecting()
    gmailConnectionService.clearError = ProductAccountSessionTestError.gmailCleanupFailed
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: "apple-user-002",
          identityToken: "token-002"
        )
      ),
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: sessionStore,
      mailboxConnectionService: gmailConnectionService,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.signInWithApple()

    guard case .failed = session.state else {
      return XCTFail("Expected failed state")
    }
    XCTAssertEqual(try sessionStore.load()?.productAccountId, "productAccountFixtureId")
    XCTAssertEqual(
      try sessionStore.loadPendingOutboxCleanupProductAccountId(),
      oldSnapshot.productAccountId
    )
  }

  func testSignInDoesNotOverwriteEarlierPendingOutboxCleanup() async throws {
    let currentSnapshot = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-002",
      identityToken: "current-token",
      productAccountId: "currentProductAccountId",
      trustedDeviceId: "currentTrustedDeviceId"
    )
    let sessionStore = ControllableProductAccountSessionStore(snapshot: currentSnapshot)
    try sessionStore.savePendingOutboxCleanupProductAccountId("earlierProductAccountId")
    let gmailConnectionService = RecordingGmailProviderConnecting()
    let outboxCleaner = RecordingOutboxDeliveryCleaner()
    outboxCleaner.productAccountIdClearError =
      ProductAccountSessionTestError.outboxCleanupFailed
    let productAccountService = RecordingProductAccountService(response: .preview)
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: "apple-user-003",
          identityToken: "token-003"
        )
      ),
      productAccountService: productAccountService,
      sessionStore: sessionStore,
      mailboxConnectionService: gmailConnectionService,
      outboxDeliveryService: outboxCleaner,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.signInWithApple()

    XCTAssertEqual(
      session.state,
      .failed(ProductAccountSessionError.pendingOutboxCleanup.localizedDescription)
    )
    XCTAssertEqual(try sessionStore.load(), currentSnapshot)
    XCTAssertEqual(
      try sessionStore.loadPendingOutboxCleanupProductAccountId(),
      "earlierProductAccountId"
    )
    XCTAssertTrue(gmailConnectionService.clearedSessions.isEmpty)
    XCTAssertTrue(productAccountService.materialInitializationIdentityTokens.isEmpty)
    XCTAssertNil(
      try keyMaterialStore.load(
        productAccountId: ProductAccountConnectResponse.preview.productAccountId
      )
    )
  }

  func testSignInKeepsPreviousSessionWhenOutboxCleanupTrackingFails() async throws {
    let oldSnapshot = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "old-token",
      productAccountId: "oldProductAccountId",
      trustedDeviceId: "oldTrustedDeviceId"
    )
    let sessionStore = ControllableProductAccountSessionStore(snapshot: oldSnapshot)
    sessionStore.pendingOutboxCleanupSaveError =
      ProductAccountSessionTestError.outboxCleanupMarkerSaveFailed
    let gmailConnectionService = RecordingGmailProviderConnecting()
    let outboxCleaner = RecordingOutboxDeliveryCleaner()
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: "apple-user-002",
          identityToken: "token-002"
        )
      ),
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: sessionStore,
      mailboxConnectionService: gmailConnectionService,
      outboxDeliveryService: outboxCleaner,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.signInWithApple()

    XCTAssertEqual(
      session.state,
      .failed(ProductAccountSessionTestError.outboxCleanupMarkerSaveFailed.localizedDescription)
    )
    XCTAssertEqual(try sessionStore.load(), oldSnapshot)
    XCTAssertTrue(gmailConnectionService.clearedSessions.isEmpty)
    XCTAssertTrue(outboxCleaner.clearedSessions.isEmpty)
  }

  func testSignInTracksOutboxCleanupAfterAccountSwitch() async throws {
    let oldSnapshot = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "old-token",
      productAccountId: "oldProductAccountId",
      trustedDeviceId: "oldTrustedDeviceId"
    )
    try store.save(oldSnapshot)
    let gmailConnectionService = RecordingGmailProviderConnecting()
    let outboxCleaner = RecordingOutboxDeliveryCleaner()
    outboxCleaner.clearError = ProductAccountSessionTestError.outboxCleanupFailed
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
      outboxDeliveryService: outboxCleaner,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.signInWithApple()

    guard case .signedIn(let snapshot) = session.state else {
      return XCTFail("Expected signed-in state")
    }
    XCTAssertEqual(try store.load(), snapshot)
    XCTAssertEqual(gmailConnectionService.clearedSessions, [oldSnapshot])
    XCTAssertEqual(outboxCleaner.clearedSessions, [oldSnapshot])
    XCTAssertEqual(
      try store.loadPendingOutboxCleanupProductAccountId(),
      oldSnapshot.productAccountId
    )
    XCTAssertEqual(pushUnregisterer.sessions, [oldSnapshot])
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

  // swiftlint:disable:next function_body_length
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
    try store.savePendingTrustedDeviceUnregistration(
      PendingTrustedDeviceUnregistration(
        appleUserIdentifier: snapshot.appleUserIdentifier,
        productAccountId: snapshot.productAccountId,
        trustedDeviceId: snapshot.trustedDeviceId
      )
    )
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: snapshot.productAccountId,
      allowCreation: true
    )
    let gmailConnectionService = RecordingGmailProviderConnecting()
    let outboxCleaner = RecordingOutboxDeliveryCleaner()
    let freshnessStore = RecordingMailboxSyncSuccessStore()
    let fallbackStore = RecordingFallbackClearer()
    let pushWakeupDrainer = RecordingGmailPushWakeupDrainer()
    let notificationClearer = RecordingNotificationClearer()
    let connectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .gmail,
        value: "gmail-user-001"
      )
    )
    freshnessStore.save(
      Date(),
      productAccountId: snapshot.productAccountId,
      connectionId: connectionId
    )
    var stateDuringCleanup: ProductAccountSessionState?
    var bodyPrefetchWasCancelled = false
    var cleanupEvents: [String] = []
    let mailboxRegistrationId = UUID()
    let session = ProductAccountSession(
      appleSignInService: RevokedAppleSignInService(),
      devicePushUnregistrationService: pushUnregisterer,
      genericNotificationFallbackStore: fallbackStore,
      gmailPushWakeupDrainer: pushWakeupDrainer,
      notificationClearer: notificationClearer,
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: store,
      mailboxConnectionService: gmailConnectionService,
      outboxDeliveryService: outboxCleaner,
      productSyncKeyMaterialStore: keyMaterialStore
    )
    gmailConnectionService.clearAction = {
      stateDuringCleanup = session.state
      cleanupEvents.append("mailbox")
    }
    pushWakeupDrainer.drainAction = {
      XCTAssertNotNil(
        freshnessStore.load(
          productAccountId: snapshot.productAccountId,
          connectionId: connectionId
        )
      )
      cleanupEvents.append("push")
    }
    _ = session.sharedMailboxFreshnessViewModel(
      for: snapshot,
      service: MailboxConnectionRouter(),
      successStore: freshnessStore
    )
    MailboxWorkCoordinator.shared.register(
      productAccountId: snapshot.productAccountId,
      registrationId: mailboxRegistrationId,
      cancelBodyPrefetch: { bodyPrefetchWasCancelled = true },
      isBusy: false
    )
    defer {
      MailboxWorkCoordinator.shared.unregister(
        productAccountId: snapshot.productAccountId,
        registrationId: mailboxRegistrationId
      )
    }

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
    XCTAssertEqual(gmailConnectionService.clearedSession, snapshot)
    XCTAssertEqual(outboxCleaner.clearedSessions, [snapshot])
    XCTAssertEqual(pushUnregisterer.sessions, [])
    XCTAssertEqual(stateDuringCleanup, .loading)
    XCTAssertNil(
      freshnessStore.load(
        productAccountId: snapshot.productAccountId,
        connectionId: connectionId
      )
    )
    XCTAssertTrue(bodyPrefetchWasCancelled)
    XCTAssertEqual(fallbackStore.clearedProductAccountIds, [snapshot.productAccountId])
    XCTAssertEqual(pushWakeupDrainer.drainedProductAccountIds, [snapshot.productAccountId])
    XCTAssertEqual(cleanupEvents, ["push", "mailbox"])
    XCTAssertEqual(notificationClearer.clearedProductAccountIds, [snapshot.productAccountId])
    XCTAssertEqual(pushWakeupDrainer.finishedProductAccountIds, [snapshot.productAccountId])
  }

  func testBootstrapPreservesRevokedSessionWhenOutboxCleanupFails() async throws {
    let snapshot = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "token-001",
      productAccountId: "productAccountFixtureId",
      trustedDeviceId: "trustedDeviceFixtureId"
    )
    try store.save(snapshot)
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: snapshot.productAccountId,
      allowCreation: true
    )
    let mailboxConnectionService = RecordingGmailProviderConnecting()
    let outboxCleaner = RecordingOutboxDeliveryCleaner()
    outboxCleaner.clearError = ProductAccountSessionTestError.outboxCleanupFailed
    let session = ProductAccountSession(
      appleSignInService: RevokedAppleSignInService(),
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: store,
      mailboxConnectionService: mailboxConnectionService,
      outboxDeliveryService: outboxCleaner,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.bootstrap()

    XCTAssertEqual(
      session.state,
      .failed(ProductAccountSessionTestError.outboxCleanupFailed.localizedDescription)
    )
    XCTAssertEqual(try store.load(), snapshot)
    XCTAssertNotNil(try keyMaterialStore.load(productAccountId: snapshot.productAccountId))
    XCTAssertEqual(try store.loadPendingSignOutProductAccountId(), snapshot.productAccountId)
    XCTAssertEqual(outboxCleaner.clearedSessions, [snapshot])
    XCTAssertTrue(mailboxConnectionService.clearedSessions.isEmpty)
    XCTAssertTrue(try store.loadPendingTrustedDeviceUnregistrations().isEmpty)
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

  func testBootstrapPreservesRevokedSessionWhenMailboxCleanupFails() async throws {
    let snapshot = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "token-001",
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
    gmailConnectionService.clearError = ProductAccountSessionTestError.gmailCleanupFailed
    let session = ProductAccountSession(
      appleSignInService: RevokedAppleSignInService(),
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: store,
      mailboxConnectionService: gmailConnectionService,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.bootstrap()

    XCTAssertEqual(
      session.state,
      .failed(ProductAccountSessionTestError.gmailCleanupFailed.localizedDescription)
    )
    XCTAssertEqual(try store.load(), snapshot)
    XCTAssertNotNil(
      try keyMaterialStore.load(productAccountId: snapshot.productAccountId)
    )
    XCTAssertEqual(try store.loadPendingSignOutProductAccountId(), snapshot.productAccountId)
    XCTAssertEqual(
      try store.loadUnacknowledgedRecoveryKey(productAccountId: snapshot.productAccountId),
      UnacknowledgedRecoveryKey(
        recoveryKey: "unacknowledged-key",
        recoveryWrappedAccountKey: nil
      )
    )
    XCTAssertTrue(try store.loadPendingTrustedDeviceUnregistrations().isEmpty)
    XCTAssertNil(session.unacknowledgedRecoveryKey)
    XCTAssertEqual(gmailConnectionService.clearedSession, snapshot)
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
    let outboxCleaner = RecordingOutboxDeliveryCleaner()
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
      outboxDeliveryService: outboxCleaner,
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
    XCTAssertEqual(outboxCleaner.clearedSessions, [oldSnapshot])
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
    let outboxCleaner = RecordingOutboxDeliveryCleaner()
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
      outboxDeliveryService: outboxCleaner,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.bootstrap()

    guard case .failed = session.state else {
      return XCTFail("Expected failed state")
    }
    XCTAssertEqual(try store.load(), oldSnapshot)
    XCTAssertEqual(gmailConnectionService.clearedSessions, [oldSnapshot])
    XCTAssertTrue(outboxCleaner.clearedSessions.isEmpty)
    XCTAssertEqual(pushUnregisterer.sessions, [])
  }

  func testBootstrapTracksOutboxCleanupAfterAccountSwitch() async throws {
    let oldSnapshot = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "old-token",
      productAccountId: "oldProductAccountId",
      trustedDeviceId: "oldTrustedDeviceId"
    )
    try store.save(oldSnapshot)
    let gmailConnectionService = RecordingGmailProviderConnecting()
    let outboxCleaner = RecordingOutboxDeliveryCleaner()
    outboxCleaner.clearError = ProductAccountSessionTestError.outboxCleanupFailed
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
      outboxDeliveryService: outboxCleaner,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.bootstrap()

    guard case .signedIn(let snapshot) = session.state else {
      return XCTFail("Expected signed-in state")
    }
    XCTAssertEqual(try store.load(), snapshot)
    XCTAssertEqual(gmailConnectionService.clearedSessions, [oldSnapshot])
    XCTAssertEqual(outboxCleaner.clearedSessions, [oldSnapshot])
    XCTAssertEqual(
      try store.loadPendingOutboxCleanupProductAccountId(),
      oldSnapshot.productAccountId
    )
    XCTAssertEqual(pushUnregisterer.sessions, [oldSnapshot])
  }

  func testBootstrapKeepsPreviousSessionWhenOutboxCleanupTrackingFails() async throws {
    let oldSnapshot = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "old-token",
      productAccountId: "oldProductAccountId",
      trustedDeviceId: "oldTrustedDeviceId"
    )
    let sessionStore = ControllableProductAccountSessionStore(snapshot: oldSnapshot)
    sessionStore.pendingOutboxCleanupSaveError =
      ProductAccountSessionTestError.outboxCleanupMarkerSaveFailed
    let gmailConnectionService = RecordingGmailProviderConnecting()
    let outboxCleaner = RecordingOutboxDeliveryCleaner()
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
      mailboxConnectionService: gmailConnectionService,
      outboxDeliveryService: outboxCleaner,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.bootstrap()

    XCTAssertEqual(
      session.state,
      .failed(ProductAccountSessionTestError.outboxCleanupMarkerSaveFailed.localizedDescription)
    )
    XCTAssertEqual(try sessionStore.load(), oldSnapshot)
    XCTAssertTrue(gmailConnectionService.clearedSessions.isEmpty)
    XCTAssertTrue(outboxCleaner.clearedSessions.isEmpty)
    XCTAssertTrue(pushUnregisterer.sessions.isEmpty)
  }

  func testBootstrapDoesNotOverwriteEarlierPendingOutboxCleanup() async throws {
    let currentSnapshot = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "current-token",
      productAccountId: "currentProductAccountId",
      trustedDeviceId: "currentTrustedDeviceId"
    )
    let sessionStore = ControllableProductAccountSessionStore(snapshot: currentSnapshot)
    try sessionStore.savePendingOutboxCleanupProductAccountId("earlierProductAccountId")
    let outboxCleaner = RecordingOutboxDeliveryCleaner()
    outboxCleaner.productAccountIdClearError =
      ProductAccountSessionTestError.outboxCleanupFailed
    let productAccountService = RecordingProductAccountService(response: .preview)
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: currentSnapshot.appleUserIdentifier,
          identityToken: "fresh-token"
        )
      ),
      productAccountService: productAccountService,
      sessionStore: sessionStore,
      outboxDeliveryService: outboxCleaner,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.bootstrap()

    XCTAssertEqual(
      session.state,
      .failed(ProductAccountSessionError.pendingOutboxCleanup.localizedDescription)
    )
    XCTAssertEqual(try sessionStore.load(), currentSnapshot)
    XCTAssertEqual(
      try sessionStore.loadPendingOutboxCleanupProductAccountId(),
      "earlierProductAccountId"
    )
    XCTAssertTrue(productAccountService.materialInitializationIdentityTokens.isEmpty)
    XCTAssertNil(
      try keyMaterialStore.load(
        productAccountId: ProductAccountConnectResponse.preview.productAccountId
      )
    )
  }

  func testBootstrapRetainsPendingOutboxCleanupWhenSessionOwnershipCannotBeRead() async throws {
    let snapshot = Self.restorableSnapshot
    let sessionStore = ControllableProductAccountSessionStore(snapshot: snapshot)
    try sessionStore.savePendingOutboxCleanupProductAccountId(snapshot.productAccountId)
    sessionStore.loadError = ProductAccountSessionTestError.sessionLoadFailed
    let outboxCleaner = RecordingOutboxDeliveryCleaner()
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: sessionStore,
      outboxDeliveryService: outboxCleaner,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.bootstrap()

    XCTAssertEqual(
      session.state,
      .failed(ProductAccountSessionTestError.sessionLoadFailed.localizedDescription)
    )
    XCTAssertEqual(
      try sessionStore.loadPendingOutboxCleanupProductAccountId(),
      snapshot.productAccountId
    )
    XCTAssertTrue(outboxCleaner.clearedProductAccountIds.isEmpty)
  }

  func testBootstrapRetriesTrackedOutboxCleanup() async throws {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    try store.savePendingOutboxCleanupProductAccountId("retired-product-account")
    let outboxCleaner = RecordingOutboxDeliveryCleaner()
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      productAccountService: FailingProductAccountService(),
      sessionStore: store,
      outboxDeliveryService: outboxCleaner,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.bootstrap()

    XCTAssertEqual(outboxCleaner.clearedProductAccountIds, ["retired-product-account"])
    XCTAssertNil(try store.loadPendingOutboxCleanupProductAccountId())
  }

  func testBootstrapDoesNotRunStaleCleanupForCurrentAccount() async throws {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    try store.savePendingOutboxCleanupProductAccountId(snapshot.productAccountId)
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: snapshot.productAccountId,
      allowCreation: true
    )
    let outboxCleaner = RecordingOutboxDeliveryCleaner()
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
      outboxDeliveryService: outboxCleaner,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.bootstrap()

    XCTAssertEqual(session.state, .signedIn(snapshot))
    XCTAssertTrue(outboxCleaner.clearedProductAccountIds.isEmpty)
    XCTAssertNil(try store.loadPendingOutboxCleanupProductAccountId())
  }

  func testBootstrapContinuesWhenRetiredOutboxCleanupFails() async throws {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    try store.savePendingOutboxCleanupProductAccountId("retired-product-account")
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: snapshot.productAccountId,
      allowCreation: true
    )
    let outboxCleaner = RecordingOutboxDeliveryCleaner()
    outboxCleaner.productAccountIdClearError =
      ProductAccountSessionTestError.outboxCleanupFailed
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
      outboxDeliveryService: outboxCleaner,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.bootstrap()

    XCTAssertEqual(session.state, .signedIn(snapshot))
    XCTAssertEqual(outboxCleaner.clearedProductAccountIds, ["retired-product-account"])
    XCTAssertEqual(
      try store.loadPendingOutboxCleanupProductAccountId(),
      "retired-product-account"
    )
  }

  func testBootstrapCompletesPendingSignOutBeforeRetiredOutboxCleanup() async throws {
    let snapshot = Self.restorableSnapshot
    let sessionStore = ControllableProductAccountSessionStore(snapshot: snapshot)
    try sessionStore.savePendingSignOutProductAccountId(snapshot.productAccountId)
    try sessionStore.savePendingOutboxCleanupProductAccountId("retired-product-account")
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: snapshot.productAccountId,
      allowCreation: true
    )
    let outboxCleaner = RecordingOutboxDeliveryCleaner()
    outboxCleaner.productAccountIdClearError =
      ProductAccountSessionTestError.outboxCleanupFailed
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: sessionStore,
      outboxDeliveryService: outboxCleaner,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.bootstrap()

    XCTAssertNil(try sessionStore.load())
    XCTAssertNil(try sessionStore.loadPendingSignOutProductAccountId())
    XCTAssertNil(try keyMaterialStore.load(productAccountId: snapshot.productAccountId))
    XCTAssertEqual(outboxCleaner.clearedSessions, [snapshot])
    XCTAssertEqual(outboxCleaner.clearedProductAccountIds, ["retired-product-account"])
    XCTAssertEqual(
      try sessionStore.loadPendingOutboxCleanupProductAccountId(),
      "retired-product-account"
    )
    XCTAssertEqual(session.state, .signedOut)
  }

  func testBootstrapPurgesFreshnessForInterruptedProductAccountDeletion() async throws {
    let snapshot = Self.restorableSnapshot
    let sessionStore = ControllableProductAccountSessionStore(snapshot: snapshot)
    try sessionStore.savePendingDeletedProductAccountId(snapshot.productAccountId)
    try sessionStore.savePendingSignOutProductAccountId(snapshot.productAccountId)
    let freshnessKey = "mailbox-sync-success.\(snapshot.productAccountId).gmail:account-001"
    UserDefaults.standard.set(Date(), forKey: freshnessKey)
    defer { UserDefaults.standard.removeObject(forKey: freshnessKey) }
    let pushWakeupDrainer = RecordingGmailPushWakeupDrainer()
    pushWakeupDrainer.drainAction = {
      XCTAssertNotNil(UserDefaults.standard.object(forKey: freshnessKey))
    }
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      gmailPushWakeupDrainer: pushWakeupDrainer,
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: sessionStore,
      mailboxConnectionService: RecordingGmailProviderConnecting(),
      mailboxConnectionIdLoader: StubMailboxConnectionIdLoader(connectionIds: []),
      outboxDeliveryService: RecordingOutboxDeliveryCleaner(),
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.bootstrap()

    XCTAssertNil(UserDefaults.standard.object(forKey: freshnessKey))
    XCTAssertEqual(session.state, .signedOut)
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

@MainActor
private final class RecordingMailboxSyncSuccessStore: MailboxSyncSuccessPersisting {
  private var dates: [String: Date] = [:]

  func clear(productAccountId: String) {
    let prefix = "\(productAccountId)."
    dates = dates.filter { !$0.key.hasPrefix(prefix) }
  }

  func clear(productAccountId: String, connectionId: MailboxConnectionId) {
    dates["\(productAccountId).\(connectionId.rawValue)"] = nil
  }

  func clear(
    productAccountId: String,
    except connectionIds: Set<MailboxConnectionId>
  ) {
    let prefix = "\(productAccountId)."
    let retainedKeys = Set(connectionIds.map { "\(prefix)\($0.rawValue)" })
    dates = dates.filter { !$0.key.hasPrefix(prefix) || retainedKeys.contains($0.key) }
  }

  func load(
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) -> Date? {
    dates["\(productAccountId).\(connectionId.rawValue)"]
  }

  func save(
    _ date: Date,
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) {
    dates["\(productAccountId).\(connectionId.rawValue)"] = date
  }
}

private final class RecordingFallbackClearer: GenericNotificationFallbackClearing {
  private(set) var clearedProductAccountIds: [String] = []

  func clear(productAccountId: String) {
    clearedProductAccountIds.append(productAccountId)
  }
}

private final class RecordingNotificationClearer: UserNotificationClearing {
  private(set) var clearedProductAccountIds: [String] = []

  func clear(productAccountId: String) {
    clearedProductAccountIds.append(productAccountId)
  }
}

@MainActor
private final class RecordingGmailPushWakeupDrainer: GmailPushWakeupDraining {
  var drainAction: (() -> Void)?
  private(set) var drainedProductAccountIds: [String] = []
  private(set) var finishedProductAccountIds: [String] = []

  func cancelAndDrain(productAccountId: String) async {
    drainedProductAccountIds.append(productAccountId)
    drainAction?()
  }

  func finishDraining(productAccountId: String) {
    finishedProductAccountIds.append(productAccountId)
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

private actor RevokedOnSecondRestoreSignInService: AppleSignInPerforming {
  private var restoreSessionCallCount = 0

  func signIn() async throws -> AppleSignInCredential {
    throw AppleSignInError.notAuthorized
  }

  func restoreSession(
    snapshot: ProductAccountSessionSnapshot
  ) async throws -> AppleSignInCredential {
    restoreSessionCallCount += 1
    guard restoreSessionCallCount == 1 else {
      throw AppleSignInError.notAuthorized
    }
    return AppleSignInCredential(
      appleUserIdentifier: snapshot.appleUserIdentifier,
      identityToken: snapshot.identityToken
    )
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
  private(set) var restoreSessionCallCount = 0
  private(set) var signInCallCount = 0

  init(credentials: [AppleSignInCredential]) {
    self.credentials = credentials
  }

  func signIn() async throws -> AppleSignInCredential {
    signInCallCount += 1
    return credentials.removeFirst()
  }

  func restoreSession(
    snapshot _: ProductAccountSessionSnapshot
  ) async throws -> AppleSignInCredential {
    restoreSessionCallCount += 1
    return credentials.removeFirst()
  }
}

private final class RecordingDeletionProductAccountService: ProductAccountConnecting {
  var connectError: Error?
  var deletionAction: (() -> Void)?
  var deletionAuthorizationCodes: [String] = []
  var deletionError: Error?
  var deletionResponse = ProductAccountDeletionResponse(deleted: true)
  var deletionTrustedDeviceIds: [String] = []
  var response: ProductAccountConnectResponse

  init(response: ProductAccountConnectResponse) {
    self.response = response
  }

  func connect(identityToken _: String) async throws -> ProductAccountConnectResponse {
    if let connectError { throw connectError }
    return response
  }

  func deleteProductAccount(
    authorizationCode: String,
    identityToken _: String,
    trustedDeviceId: String
  ) async throws -> ProductAccountDeletionResponse {
    deletionAuthorizationCodes.append(authorizationCode)
    deletionTrustedDeviceIds.append(trustedDeviceId)
    deletionAction?()
    if let deletionError { throw deletionError }
    return deletionResponse
  }

  func markProductSyncMaterialInitialized(
    identityToken _: String,
    trustedDeviceId _: String
  ) async throws -> ProductSyncMaterialInitializedResponse {
    ProductSyncMaterialInitializedResponse(productSyncMaterialInitialized: true)
  }

  func productSyncRecoveryIsBackedUp(
    identityToken _: String,
    expectedRecoveryWrappedAccountKey _: ProductSyncEncryptedPayload?
  ) async throws -> Bool {
    true
  }

  func unregisterTrustedDevice(
    identityToken _: String,
    trustedDeviceId _: String
  ) async throws -> TrustedDeviceUnregistrationResponse {
    TrustedDeviceUnregistrationResponse(registered: false)
  }
}

private final class RecordingDeletionMailActionService: MailboxProviderMailActing {
  private(set) var resumePendingActionsCallCount = 0

  func perform(
    _: ProviderMailAction,
    messages _: [MailboxMessageMetadata],
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws {}

  func resumePendingActions(
    connections _: [MailboxConnection],
    session _: ProductAccountSessionSnapshot
  ) async -> String? {
    resumePendingActionsCallCount += 1
    return nil
  }

  func send(
    _: OutgoingMessage,
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws {}
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
  case outboxCleanupFailed
  case outboxCleanupMarkerSaveFailed
  case pushUnregistrationFailed
  case sessionClearFailed
  case sessionLoadFailed
  case sessionSaveFailed
  case trustedDeviceUnregistrationFailed
  case unexpectedAuthenticationRequest
}

private final class RecordingProductSyncCacheClearer: ProductSyncCacheClearing {
  private(set) var clearedProductAccountIds: [String] = []

  func clear(productAccountId: String) throws {
    clearedProductAccountIds.append(productAccountId)
  }
}

private struct StubMailboxConnectionIdLoader: MailboxConnectionIdLoading {
  let connectionIds: [MailboxConnectionId]
  var error: Error?

  init(connectionIds: [MailboxConnectionId], error: Error? = nil) {
    self.connectionIds = connectionIds
    self.error = error
  }

  func loadConnectionIds(session _: ProductAccountSessionSnapshot) async throws
    -> [MailboxConnectionId]
  {
    if let error { throw error }
    return connectionIds
  }
}

private struct StubMailboxConnectionSnapshotLoader: MailboxConnectionSnapshotLoading {
  let snapshot: MailboxConnectionLoadSnapshot

  func loadConnectionSnapshot(
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionLoadSnapshot {
    snapshot
  }
}

private final class RecordingProductAccountService: ProductAccountConnecting {
  var materialInitializationIdentityTokens: [String] = []
  var recoveryBackedUp = true
  var recoveryCheckCount = 0
  var recoveryCheckExpectedWrappedAccountKeys: [ProductSyncEncryptedPayload?] = []
  var recoveryCheckIdentityTokens: [String] = []
  var recoveryCheckAction: (() -> Void)?
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
    recoveryCheckAction?()
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

private struct EmptyProductAccountPendingActionStore: PendingProviderActionPersisting {
  func load(productAccountId _: String) throws -> [PendingProviderAction] { [] }

  func save(
    _: [PendingProviderAction],
    productAccountId _: String
  ) throws {}
}

private final class ProductAccountOutboxStore: OutboxDeliveryPersisting, @unchecked Sendable {
  var clearError: Error?
  private var attemptsByProductAccountId: [String: [OutgoingDeliveryAttempt]] = [:]

  func clear(productAccountId: String) throws {
    if let clearError { throw clearError }
    attemptsByProductAccountId[productAccountId] = nil
  }

  func load(productAccountId: String) throws -> [OutgoingDeliveryAttempt] {
    attemptsByProductAccountId[productAccountId] ?? []
  }

  func save(
    _ attempts: [OutgoingDeliveryAttempt],
    productAccountId: String
  ) throws {
    attemptsByProductAccountId[productAccountId] = attempts
  }
}

private final class ControllableProductAccountSessionStore: ProductAccountSessionPersisting {
  var didClear = false
  var loadCount = 0
  var loadError: Error?
  var saveError: Error?
  var saveErrorOnCall: Int?
  var clearError: Error?
  var unacknowledgedRecoveryKeySaveError: Error?
  var pendingOutboxCleanupSaveError: Error?

  private var pendingDeletedProductAccountId: String?
  private var pendingSignOutProductAccountId: String?
  private var pendingOutboxCleanupProductAccountId: String?
  private var pendingTrustedDeviceUnregistrations: [String: PendingTrustedDeviceUnregistration] =
    [:]
  private var snapshot: ProductAccountSessionSnapshot?
  private var saveCallCount = 0
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
    saveCallCount += 1
    if let saveError, saveErrorOnCall == nil || saveErrorOnCall == saveCallCount {
      throw saveError
    }
    if saveErrorOnCall == saveCallCount {
      throw ProductAccountSessionTestError.sessionSaveFailed
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

  func loadPendingDeletedProductAccountId() throws -> String? {
    pendingDeletedProductAccountId
  }

  func savePendingDeletedProductAccountId(_ productAccountId: String) throws {
    pendingDeletedProductAccountId = productAccountId
  }

  func clearPendingDeletedProductAccountId() throws {
    pendingDeletedProductAccountId = nil
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

  func loadPendingOutboxCleanupProductAccountId() throws -> String? {
    pendingOutboxCleanupProductAccountId
  }

  func savePendingOutboxCleanupProductAccountId(_ productAccountId: String) throws {
    if let pendingOutboxCleanupSaveError {
      throw pendingOutboxCleanupSaveError
    }
    pendingOutboxCleanupProductAccountId = productAccountId
  }

  func clearPendingOutboxCleanupProductAccountId() throws {
    pendingOutboxCleanupProductAccountId = nil
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

private final class RecordingOutboxDeliveryCleaner: OutboxDeliveryClearing {
  var clearError: Error?
  var productAccountIdClearError: Error?
  private(set) var clearedSessions: [ProductAccountSessionSnapshot] = []
  private(set) var clearedProductAccountIds: [String] = []
  private(set) var suspendedProductAccountIds: [String] = []

  func clear(session: ProductAccountSessionSnapshot) async throws {
    clearedSessions.append(session)
    if let clearError { throw clearError }
  }

  func clear(productAccountId: String) async throws {
    clearedProductAccountIds.append(productAccountId)
    if let productAccountIdClearError { throw productAccountIdClearError }
    if let clearError { throw clearError }
  }

  func suspend(productAccountId: String) async {
    suspendedProductAccountIds.append(productAccountId)
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
