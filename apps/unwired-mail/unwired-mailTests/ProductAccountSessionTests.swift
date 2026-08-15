import AuthenticationServices
import Foundation
import Testing

@testable import unwired_mail

// swiftlint:disable file_length type_body_length
@MainActor
@Suite(.serialized)
final class ProductAccountSessionTests {
  private var store = InMemoryProductAccountSessionStore()
  private var keyMaterialStore = InMemoryProductSyncKeyMaterialStore()
  private var pushUnregisterer = RecordingDevicePushUnregisterer()

  init() {
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

  private func makeRecoveryPendingSession(
    reconnectError: Error,
    retryAppleUserIdentifier: String = "apple-user-001"
  ) throws -> ProductAccountSession {
    let recoveryMaterial = try ProductSyncKeyMaterial.create()
    let productAccountService = RecordingProductAccountService(response: .resumed)
    productAccountService.recoveryMaterial = EncryptedProductSyncPayload(
      encryptedPayload: recoveryMaterial.recoveryWrappedAccountKey,
      payloadIdentifier: AccountAndDevicesService.recoveryPayloadIdentifier,
      updatedAt: 1
    )
    productAccountService.connectErrorAfterFirstCall = reconnectError
    return ProductAccountSession(
      appleSignInService: SequencedAppleSignInService(
        credentials: [
          AppleSignInCredential(
            appleUserIdentifier: "apple-user-001",
            identityToken: "initial-token"
          ),
          AppleSignInCredential(
            appleUserIdentifier: retryAppleUserIdentifier,
            identityToken: "retry-token"
          ),
        ]
      ),
      productAccountService: productAccountService,
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore
    )
  }

  #if MAIL_TEST_BOOTSTRAP
    @Test
    func testMailTestBootstrapBypassesProductionBootstrapAndForegroundRevalidation() async throws {
      let snapshot = Self.restorableSnapshot
      let productAccountService = RecordingProductAccountService(response: .preview)
      let session = ProductAccountSession(
        appleSignInService: RevokedAppleSignInService(),
        productAccountService: productAccountService,
        sessionStore: store,
        productSyncKeyMaterialStore: keyMaterialStore
      )
      session.activateMailTestBootstrap(snapshot)

      await session.bootstrap()
      let remainsAuthorized = await session.revalidateTrustedDeviceAfterForegrounding()

      #expect(session.state == .signedIn(snapshot))
      #expect(remainsAuthorized)
      #expect(productAccountService.connectIdentityTokens.isEmpty)
      #expect(try store.load() == nil)
    }
  #endif

  @Test
  func testSignInStoresSessionAndMovesToSignedInState() async throws {
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
      Issue.record("Expected signed-in state")
      return
    }

    #expect(snapshot.productAccountId == ProductAccountConnectResponse.preview.productAccountId)
    #expect(snapshot.identityTokenExpiresAt == Date(timeIntervalSince1970: 1_000))
    #expect(try store.load() == snapshot)
    #expect(try keyMaterialStore.load(productAccountId: snapshot.productAccountId) != nil)
  }

  @Test
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
      Issue.record("Expected signed-in state")
      return
    }
    #expect(snapshot.appleUserIdentifier == "apple-user-002")
    #expect(try store.load() == snapshot)
    #expect(try store.loadPendingSignOutProductAccountId() == nil)
    #expect(try keyMaterialStore.load(productAccountId: oldSnapshot.productAccountId) == nil)
    #expect(
      try store.loadPendingTrustedDeviceUnregistrations() == [
        PendingTrustedDeviceUnregistration(
          appleUserIdentifier: oldSnapshot.appleUserIdentifier,
          productAccountId: oldSnapshot.productAccountId,
          trustedDeviceId: oldSnapshot.trustedDeviceId
        )
      ])
  }

  @Test
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
      Issue.record("Expected signed-in state")
      return
    }

    let token = try await session.recentIdentityToken(
      for: currentSnapshot
    )

    #expect(token == "fresh-token")
  }

  @Test
  // swiftlint:disable:next function_body_length
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
    let notificationClearer = RecordingNotificationClearer()
    let gmailConnectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .gmail,
        value: "provider-account-001"
      )
    )
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          authorizationCode: "recent-authorization-code",
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      notificationClearer: notificationClearer,
      productAccountService: accountService,
      sessionStore: store,
      mailboxConnectionService: mailboxConnectionService,
      mailboxConnectionIdLoader: StubMailboxConnectionIdLoader(
        connectionIds: [gmailConnectionId]
      ),
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

    #expect(session.state == .signedOut)
    #expect(accountService.deletionAuthorizationCodes == ["recent-authorization-code"])
    #expect(accountService.deletionTrustedDeviceIds == [snapshot.trustedDeviceId])
    #expect(mailboxConnectionService.clearedSessions == [snapshot])
    #expect(outboxCleaner.clearedSessions == [snapshot])
    #expect(try store.load() == nil)
    #expect(try keyMaterialStore.load(productAccountId: snapshot.productAccountId) == nil)
    #expect(productSyncCacheClearer.clearedProductAccountIds == [snapshot.productAccountId])
    #expect(
      notificationClearer.events
        == ["migrate:\(snapshot.productAccountId)", "clear:\(snapshot.productAccountId)"]
    )
    #expect(
      notificationClearer.migratedGmailProviderAccountIdentifiers
        == [[gmailConnectionId.providerMailboxIdentity.value]]
    )
    #expect(mailActionViewModel.isPreparingForSignOut)
    #expect(try store.loadPendingTrustedDeviceUnregistrations() == [])
  }

  @Test
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
      #expect(mailActionViewModel.isPreparingForSignOut)
    }

    await session.deleteProductAccount()
    #expect(session.state == .signedIn(snapshot))
    #expect(!(mailActionViewModel.isPreparingForSignOut))
    #expect(mailActionService.resumePendingActionsCallCount == 1)
  }

  @Test
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

    #expect(session.state == .signedIn(snapshot))
    #expect(!(mailActionViewModel.isPreparingForSignOut))
    #expect(mailActionService.resumePendingActionsCallCount == 1)
    #expect(
      session.deletionErrorMessage
        == ProductAccountSessionError.differentAppleAccount.localizedDescription)
  }

  @Test
  func testProductAccountDeletionRollsBackWhenReconnectFails() async throws {
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
    accountService.connectError = ProductAccountSessionTestError.sessionLoadFailed
    let mailActionService = RecordingDeletionMailActionService()
    let mailActionViewModel = session.sharedMailActionViewModel(
      for: snapshot,
      service: mailActionService
    )

    await session.deleteProductAccount()

    #expect(session.state == .signedIn(snapshot))
    #expect(!(mailActionViewModel.isPreparingForSignOut))
    #expect(mailActionService.resumePendingActionsCallCount == 1)
    #expect(
      session.deletionErrorMessage
        == ProductAccountSessionTestError.sessionClearFailed.localizedDescription)
  }

  @Test
  func testProductAccountDeletionRequiresReconnectWhenFailureRecoveryCredentialIsStale()
    async throws
  {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: snapshot.productAccountId,
      allowCreation: true
    )
    let credentialStore = InMemoryTrustedDeviceCredentialStore(
      credentials: [snapshot.trustedDeviceId: "stale-credential"]
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
      productSyncKeyMaterialStore: keyMaterialStore,
      trustedDeviceCredentialStore: credentialStore
    )
    await session.bootstrap()
    accountService.connectError = ProductAccountServiceError.trustedDeviceReconnectRequired

    await session.deleteProductAccount()

    #expect(
      session.state
        == .failed(ProductAccountServiceError.trustedDeviceReconnectRequired.localizedDescription))
    #expect(
      session.deletionErrorMessage
        == ProductAccountServiceError.trustedDeviceReconnectRequired.localizedDescription)
    #expect(try credentialStore.load(trustedDeviceId: snapshot.trustedDeviceId) == nil)
  }

  @Test
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

    #expect(connectionIds == [localConnectionId])
  }

  @Test
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

    #expect(connectionIds == [snapshotConnectionId])
  }

  @Test
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
      Issue.record("Expected cancellation")
    } catch {
      #expect(error is CancellationError)
    }
  }

  @Test
  func testDeviceLocalConnectionIdLoaderContinuesAfterOneProviderFails() async throws {
    let genericConnectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .imapSMTP,
        value: "generic-account"
      )
    )
    let loader = DeviceLocalMailboxConnectionIdLoader(
      exchangeWebServicesStore: FailingConnectionIdEWSAuthorizationStore(),
      genericMailStore: StubGenericMailAuthStore(
        connectionIds: [genericConnectionId]
      ),
      gmailStore: InMemoryGmailProviderTokenStore(),
      microsoftGraphStore: InMemoryMicrosoftGraphAuthorizationStore()
    )

    let connectionIds = try await loader.loadConnectionIds(session: Self.restorableSnapshot)

    #expect(connectionIds == [genericConnectionId])
  }

  @Test
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

    #expect(preferences.remoteContentOverride(for: deletedConnectionId) == nil)
    #expect(preferences.remoteContentOverride(for: retainedConnectionId) == .alwaysLoad)
  }

  @Test
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

    #expect(session.state == .signedOut)
    #expect(mailboxConnectionService.clearedSessions == [snapshot])
    #expect(notificationClearer.clearedProductAccountIds == [snapshot.productAccountId])
  }

  @Test
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

    #expect(session.state == .signedOut)
    #expect(try store.load() == nil)
    #expect(try keyMaterialStore.load(productAccountId: snapshot.productAccountId) == nil)
    #expect(mailboxConnectionService.clearedSessions == [snapshot])
    #expect(outboxCleaner.clearedSessions == [snapshot])
    #expect(session.deletionErrorMessage == nil)
  }

  @Test
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

    #expect(session.state == .signedOut)
    #expect(try store.load() == nil)
    #expect(accountService.deletionAuthorizationCodes == ["recent-authorization-code"])
    #expect(session.deletionErrorMessage == nil)
  }

  @Test
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

    #expect(
      session.state
        == .failed(ProductAccountSessionTestError.outboxCleanupFailed.localizedDescription))
    #expect(try store.loadPendingDeletedProductAccountId() == snapshot.productAccountId)
    #expect(pushWakeupDrainer.drainedProductAccountIds == [snapshot.productAccountId])
    #expect(pushWakeupDrainer.finishedProductAccountIds == [])
  }

  @Test
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

    #expect(try store.load() == snapshot)
    #expect(accountService.deletionAuthorizationCodes == [])
    #expect(mailboxConnectionService.clearedSessions == [])
    #expect(
      session.deletionErrorMessage
        == ProductAccountSessionError.differentAppleAccount.localizedDescription)
  }

  @Test
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
      #expect(UserDefaults.standard.object(forKey: freshnessKey) != nil)
    }
    mailboxConnectionService.clearAction = {
      stateDuringCleanup = session.state
    }
    await session.bootstrap()
    accountService.connectError = ProductAccountServiceError.productAccountDeleted

    await session.revalidateProductAccountAfterForegrounding()

    #expect(session.state == .signedOut)
    #expect(try store.load() == nil)
    #expect(try keyMaterialStore.load(productAccountId: snapshot.productAccountId) == nil)
    #expect(mailboxConnectionService.clearedSessions == [snapshot])
    #expect(pushWakeupDrainer.drainedProductAccountIds == [snapshot.productAccountId])
    #expect(stateDuringCleanup == .loading)
    #expect(UserDefaults.standard.object(forKey: freshnessKey) == nil)
  }

  @Test
  func testDeletedAccountClearsCredentialBeforeFallibleLocalCleanup() async throws {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: snapshot.productAccountId,
      allowCreation: true
    )
    let credentialStore = InMemoryTrustedDeviceCredentialStore(
      credentials: [snapshot.trustedDeviceId: "deleted-account-credential"]
    )
    let outboxCleaner = RecordingOutboxDeliveryCleaner()
    outboxCleaner.clearError = ProductAccountSessionTestError.outboxCleanupFailed
    outboxCleaner.clearAction = {
      #expect(throws: Never.self) {
        let credential = try credentialStore.load(trustedDeviceId: snapshot.trustedDeviceId)
        #expect(credential == nil)
      }
    }
    let accountService = RecordingDeletionProductAccountService(response: Self.restorableResponse)
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      productAccountService: accountService,
      sessionStore: store,
      outboxDeliveryService: outboxCleaner,
      productSyncKeyMaterialStore: keyMaterialStore,
      trustedDeviceCredentialStore: credentialStore
    )
    await session.bootstrap()
    accountService.connectError = ProductAccountServiceError.productAccountDeleted

    await session.revalidateProductAccountAfterForegrounding()

    #expect(
      session.state
        == .failed(ProductAccountSessionTestError.outboxCleanupFailed.localizedDescription))
    #expect(try credentialStore.load(trustedDeviceId: snapshot.trustedDeviceId) == nil)
  }

  @Test
  func testProductAccountForegroundRevalidationSurfacesReconnectAndClearsCredential()
    async throws
  {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: snapshot.productAccountId,
      allowCreation: true
    )
    let credentialStore = InMemoryTrustedDeviceCredentialStore(
      credentials: [snapshot.trustedDeviceId: "stale-credential"]
    )
    let accountService = RecordingDeletionProductAccountService(response: Self.restorableResponse)
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      productAccountService: accountService,
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore,
      trustedDeviceCredentialStore: credentialStore
    )
    await session.bootstrap()
    accountService.connectError = ProductAccountServiceError.trustedDeviceReconnectRequired

    await session.revalidateProductAccountAfterForegrounding()

    #expect(
      session.state
        == .failed(ProductAccountServiceError.trustedDeviceReconnectRequired.localizedDescription))
    #expect(try credentialStore.load(trustedDeviceId: snapshot.trustedDeviceId) == nil)
  }

  @Test
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
      Issue.record("Expected signed-in state")
      return
    }
    #expect(refreshedSnapshot.identityToken == "fresh-token")
    #expect(try store.load() == refreshedSnapshot)
    let refreshedFreshnessViewModel = session.sharedMailboxFreshnessViewModel(
      for: refreshedSnapshot,
      service: MailboxConnectionRouter()
    )
    #expect(staleFreshnessViewModel === refreshedFreshnessViewModel)
    let signInCallCount = await appleSignInService.signInCallCount
    let restoreSessionCallCount = await appleSignInService.restoreSessionCallCount
    #expect(signInCallCount == 0)
    #expect(restoreSessionCallCount == 2)
  }

  @Test
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

    #expect(session.state == .signedOut)
    #expect(try store.load() == nil)
    #expect(try keyMaterialStore.load(productAccountId: snapshot.productAccountId) == nil)
    #expect(mailboxConnectionService.clearedSessions == [snapshot])
    #expect(outboxCleaner.clearedSessions == [snapshot])
    #expect(mailActionViewModel.isPreparingForSignOut)
  }

  @Test
  func testTrustedDeviceDisplayNameUsesTheBackendUTF16Limit() {
    let displayName = TrustedDeviceIdentity.normalizedDisplayName(
      String(repeating: "😀", count: 50),
      platform: "ios"
    )

    #expect(displayName.count == 40)
    #expect(displayName.utf16.count == 80)
    let oversizedFirstCharacter = "a" + String(repeating: "\u{0301}", count: 80)
    #expect(
      TrustedDeviceIdentity.normalizedDisplayName(oversizedFirstCharacter, platform: "ios")
        == "This Apple Device")
  }

  @Test
  func testAuthenticationPresentationAnchorsPreserveKeyWindowAcrossActiveScenesOffMainThread()
    async
  {
    let callbackInput = makeAuthenticationPresentationFixture()
    let callbackCompleted = expectation(description: "Presentation callbacks complete")

    DispatchQueue.global().async {
      #expect(!(Thread.isMainThread))
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
      #expect(appleAnchor === callbackInput.authenticationWindow)
      for provider in callbackInput.webProviders {
        let webAnchor = provider.presentationAnchor(for: webAuthenticationSession)
        #expect(webAnchor === callbackInput.authenticationWindow)
      }
      callbackCompleted.fulfill()
    }

    await fulfillment(of: [callbackCompleted], timeout: 1)
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
    #expect(presentationAnchorStore.captureCurrent())
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

  @Test
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

    #expect(mailViewModel === settingsViewModel)
  }

  @Test
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

    #expect(mailViewModel === settingsViewModel)
  }

  @Test
  func testSharedMailboxViewModelsSurviveIdentityTokenRefresh() {
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: "apple-user-001",
          identityToken: "token-001"
        )
      ),
      sessionStore: store
    )
    let refreshedSnapshot = ProductAccountSessionSnapshot(
      appleUserIdentifier: Self.restorableSnapshot.appleUserIdentifier,
      identityToken: "token-refreshed",
      productAccountId: Self.restorableSnapshot.productAccountId,
      trustedDeviceId: Self.restorableSnapshot.trustedDeviceId
    )
    let freshnessViewModel = session.sharedMailboxFreshnessViewModel(
      for: Self.restorableSnapshot,
      service: MailboxConnectionRouter()
    )
    let mailActionViewModel = session.sharedMailActionViewModel(
      for: Self.restorableSnapshot,
      service: MailboxConnectionRouter()
    )

    #expect(
      freshnessViewModel
        === session.sharedMailboxFreshnessViewModel(
          for: refreshedSnapshot,
          service: MailboxConnectionRouter()
        ))
    #expect(
      mailActionViewModel
        === session.sharedMailActionViewModel(
          for: refreshedSnapshot,
          service: MailboxConnectionRouter()
        ))
    #expect(!(mailActionViewModel.isPreparingForSignOut))
  }

  @Test
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

    #expect(!(previousViewModel === replacementViewModel))
    #expect(previousViewModel.isPreparingForSignOut)
  }

  @Test
  func testAppleIdentityTokenExpirationRejectsUnverifiableClaims() {
    let invalidTokens = [
      "not-an-identity-token",
      "e30.!.signature",
      "e30.e30.signature",
      "e30.eyJleHAiOiJzb29uIn0.signature",
    ]

    for token in invalidTokens {
      #expect(AppleIdentityToken.expirationDate(from: token) == nil)
    }
  }

  @Test
  func testAppleIdentityTokenExpirationReadsNumericClaim() {
    #expect(
      AppleIdentityToken.expirationDate(from: "e30.eyJleHAiOjEwMDB9.signature")
        == Date(timeIntervalSince1970: 1_000))
  }

  @Test
  func testAppleAuthorizationCodeIsOptionalOutsideAccountDeletion() {
    #expect(SignInWithAppleService.decodedAuthorizationCode(from: nil) == nil)
    #expect(SignInWithAppleService.decodedAuthorizationCode(from: Data("code".utf8)) == "code")
  }

  @Test
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

    #expect(
      credential
        == AppleSignInCredential(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        ))
  }

  @Test
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
        Issue.record("Expected \(state) authorization to be rejected")
      } catch {
        #expect(error as? AppleSignInError == .notAuthorized)
      }
    }
  }

  @Test
  func testRestoreSessionReportsUnavailableAppleCredentialState() async {
    let service = SignInWithAppleService(
      authorizationStateChecker: StubAuthorizationChecker(
        state: .unavailable
      )
    )

    do {
      _ = try await service.restoreSession(snapshot: Self.restorableSnapshot)
      Issue.record("Expected unavailable authorization state to fail restoration")
    } catch {
      #expect(error as? AppleSignInError == .credentialUnavailable)
    }
  }

  @Test
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
    let activeController = try requireValue(controllers.first)
    let unrelatedController = ASAuthorizationController(
      authorizationRequests: [ASAuthorizationAppleIDProvider().createRequest()]
    )

    service.authorizationController(
      controller: unrelatedController,
      didCompleteWithError: CancellationError()
    )

    do {
      _ = try await service.signIn()
      Issue.record("Expected overlapping authorization to be rejected")
    } catch {
      #expect(error as? AppleSignInError == .authorizationInProgress)
    }

    service.authorizationController(
      controller: activeController,
      didCompleteWithError: CancellationError()
    )
    do {
      _ = try await firstSignIn.value
      Issue.record("Expected the active authorization to be cancelled")
    } catch is CancellationError {
    }

    let retrySignIn = Task { try await service.signIn() }
    await fulfillment(of: [retryRequestStarted])
    let retryController = try requireValue(controllers.last)
    service.authorizationController(
      controller: retryController,
      didCompleteWithError: CancellationError()
    )
    do {
      _ = try await retrySignIn.value
      Issue.record("Expected the retry authorization to be cancelled")
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

  @Test
  func testSignOutClearsStoredSession() async throws {
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

    #expect(session.state == .signedOut)
    #expect(try store.load() == nil)
    #expect(
      gmailConnectionService.clearedSession?.productAccountId
        == ProductAccountConnectResponse.preview.productAccountId)
    #expect(
      pushUnregisterer.sessions.first?.productAccountId
        == ProductAccountConnectResponse.preview.productAccountId)
    #expect(
      productAccountService.unregisteredTrustedDeviceIds == [
        ProductAccountConnectResponse.preview.trustedDeviceId
      ])
    #expect(
      outboxCleaner.clearedSessions.map(\.productAccountId) == [
        ProductAccountConnectResponse.preview.productAccountId
      ])
    #expect(
      try keyMaterialStore.load(
        productAccountId: ProductAccountConnectResponse.preview.productAccountId
      ) == nil)
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testSignOutClearsComposePreferencesBeforeSameAccountSignIn() async throws {
    let localStateStore = TestComposeLocalStateStore()
    let syncService = TestComposeSyncService()
    let inboxLocalStateStore = TestInboxLocalStateStore()
    let inboxSyncService = TestInboxSyncService()
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: "apple-user-001",
          identityToken: "token-001"
        )
      ),
      devicePushUnregistrationService: pushUnregisterer,
      productAccountService: RecordingProductAccountService(response: .preview),
      sessionStore: store,
      composePreferenceLocalStateStore: localStateStore,
      inboxPreferenceLocalStateStore: inboxLocalStateStore,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.signInWithApple()
    guard case .signedIn(let firstSnapshot) = session.state else {
      Issue.record("Expected signed-in state")
      return
    }
    let firstStore = session.sharedComposePreferenceStore(
      for: firstSnapshot,
      syncService: syncService
    )
    firstStore.setUndoSendWindow(.thirtySeconds)
    let firstInboxStore = session.sharedInboxPreferenceStore(
      for: firstSnapshot,
      syncService: inboxSyncService
    )
    firstInboxStore.setThreadDensity(.compact)

    await session.signOut()
    await session.signInWithApple()
    guard case .signedIn(let secondSnapshot) = session.state else {
      Issue.record("Expected same-account sign-in after sign-out")
      return
    }
    let secondStore = session.sharedComposePreferenceStore(
      for: secondSnapshot,
      syncService: syncService
    )
    let secondInboxStore = session.sharedInboxPreferenceStore(
      for: secondSnapshot,
      syncService: inboxSyncService
    )

    #expect(secondStore !== firstStore)
    #expect(secondStore.preferences == .defaults)
    #expect(try localStateStore.load(productAccountId: secondSnapshot.productAccountId) == nil)
    #expect(secondInboxStore !== firstInboxStore)
    #expect(secondInboxStore.preferences == .defaults)
    #expect(try inboxLocalStateStore.load(productAccountId: secondSnapshot.productAccountId) == nil)
  }

  @Test
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
      #expect(outboxCleaner.suspendedProductAccountIds == [snapshot.productAccountId])
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

    #expect(session.state == .signedIn(snapshot))
    #expect(
      session.signOutErrorMessage
        == ProductAccountSessionError.recoveryNotBackedUp.localizedDescription)
    #expect(try store.load() == snapshot)
    #expect(try keyMaterialStore.load(productAccountId: snapshot.productAccountId) == material)
    #expect(gmailConnectionService.clearedSessions == [])
    #expect(pushUnregisterer.sessions == [])
    #expect(productAccountService.unregisteredTrustedDeviceIds == [])
    #expect(
      productAccountService.recoveryCheckExpectedWrappedAccountKeys == [
        material.recoveryWrappedAccountKey
      ])
    #expect(!(didPrepareDestructiveCleanup))
  }

  @Test
  func testSignOutAllowsAuthoritativePendingRotationWithOfflineDevice() async throws {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    let original = try keyMaterialStore.ensureMaterial(
      productAccountId: snapshot.productAccountId,
      allowCreation: true
    )
    let rotated = try original.rotatingAccountKey(
      toVersion: original.accountKeyVersion + 1
    )
    try keyMaterialStore.save(rotated, productAccountId: snapshot.productAccountId)
    let productAccountService = RecordingProductAccountService(response: .preview)
    productAccountService.recoveryBackedUp = false
    productAccountService.rotationResponse = ProductSyncKeyRotationResponse(
      keyEpoch: rotated.accountKeyVersion,
      pendingDeviceCount: 1,
      state: .pending
    )
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

    #expect(session.state == .signedOut)
    #expect(try store.load() == nil)
    #expect(try keyMaterialStore.load(productAccountId: snapshot.productAccountId) == nil)
    #expect(productAccountService.unregisteredTrustedDeviceIds == [snapshot.trustedDeviceId])
  }

  @Test
  func testSignOutRejectsMatchingPendingRotationWithUnacknowledgedRecoveryKey() async throws {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    let original = try keyMaterialStore.ensureMaterial(
      productAccountId: snapshot.productAccountId,
      allowCreation: true
    )
    let rotated = try original.rotatingAccountKey(
      toVersion: original.accountKeyVersion + 1
    )
    try keyMaterialStore.save(rotated, productAccountId: snapshot.productAccountId)
    let productAccountService = RecordingProductAccountService(response: Self.restorableResponse)
    productAccountService.recoveryBackedUp = false
    productAccountService.rotationResponse = ProductSyncKeyRotationResponse(
      keyEpoch: rotated.accountKeyVersion,
      pendingDeviceCount: 1,
      state: .pending
    )
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
    await session.bootstrap()
    try session.preserveUnacknowledgedRecoveryKey("unacknowledged-key")

    await session.signOut()

    #expect(session.state == .signedIn(snapshot))
    #expect(
      session.signOutErrorMessage
        == ProductAccountSessionError.recoveryNotBackedUp.localizedDescription)
    #expect(session.unacknowledgedRecoveryKey == "unacknowledged-key")
    #expect(productAccountService.unregisteredTrustedDeviceIds == [])
  }

  @Test
  func testSignOutRejectsPendingRotationForDifferentLocalKeyEpoch() async throws {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    let material = try keyMaterialStore.ensureMaterial(
      productAccountId: snapshot.productAccountId,
      allowCreation: true
    )
    let productAccountService = RecordingProductAccountService(response: .preview)
    productAccountService.recoveryBackedUp = false
    productAccountService.rotationResponse = ProductSyncKeyRotationResponse(
      keyEpoch: material.accountKeyVersion + 1,
      pendingDeviceCount: 1,
      state: .pending
    )
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      productAccountService: productAccountService,
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.signOut()

    #expect(session.state == .signedIn(snapshot))
    #expect(
      session.signOutErrorMessage
        == ProductAccountSessionError.recoveryNotBackedUp.localizedDescription)
    #expect(try store.load() == snapshot)
    #expect(productAccountService.unregisteredTrustedDeviceIds == [])
  }

  @Test
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

    #expect(productAccountService.recoveryCheckIdentityTokens == ["fresh-token"])
    #expect(productAccountService.unregistrationIdentityTokens == ["fresh-token"])
    #expect(pushUnregisterer.sessions.map(\.identityToken) == ["fresh-token"])
    #expect(mailboxConnectionService.clearedSessions.map(\.identityToken) == ["fresh-token"])
    #expect(session.state == .signedOut)
  }

  @Test
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

    #expect(productAccountService.recoveryCheckIdentityTokens == ["fresh-token"])
    #expect(productAccountService.unregistrationIdentityTokens == ["fresh-token"])
    #expect(session.state == .signedOut)
  }

  @Test
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
      Issue.record("Expected bootstrap to restore the Product Account")
      return
    }
    await productAccountRecoveryOperationGate.acquire(
      productAccountId: activeSnapshot.productAccountId
    )

    let signOut = Task { await session.signOut() }
    await waitForRecoveryOperationWaiter(
      productAccountId: activeSnapshot.productAccountId
    )

    #expect(session.state == .signedIn(activeSnapshot))

    await productAccountRecoveryOperationGate.release(
      productAccountId: activeSnapshot.productAccountId
    )
    await signOut.value
    #expect(session.state == .signedOut)
  }

  @Test
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
      Issue.record("Expected bootstrap to restore the Product Account")
      return
    }
    try session.preserveUnacknowledgedRecoveryKey("unacknowledged-key")

    await session.signOut()

    #expect(session.state == .signedIn(activeSnapshot))
    #expect(
      session.signOutErrorMessage
        == ProductAccountSessionError.recoveryNotBackedUp.localizedDescription)
    #expect(session.unacknowledgedRecoveryKey == "unacknowledged-key")
  }

  @Test
  func testSignOutReloadsRecoveryMarkerClearedByReconciliationWithoutRestart() async throws {
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
      Issue.record("Expected bootstrap to restore the Product Account")
      return
    }
    try session.preserveUnacknowledgedRecoveryKey("reconciled-key")
    try store.clearUnacknowledgedRecoveryKey(productAccountId: activeSnapshot.productAccountId)

    await session.signOut()

    #expect(session.state == .signedOut)
    #expect(session.unacknowledgedRecoveryKey == nil)
  }

  @Test
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
    let material = try requireValue(try keyMaterialStore.load(productAccountId: productAccountId))
    try keyMaterialStore.save(
      material.replacingRecoveryKey(),
      productAccountId: productAccountId
    )

    #expect {
      try session.preserveUnacknowledgedRecoveryKey("second-key")
    } throws: { error in
      #expect(error as? ProductAccountSessionError == .recoveryKeyUnacknowledged)
      return true
    }

    #expect(session.unacknowledgedRecoveryKey == "first-key")
    let persistedMarker = try store.loadUnacknowledgedRecoveryKey(
      productAccountId: productAccountId
    )
    #expect(persistedMarker?.recoveryKey == "first-key")
  }

  @Test
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
      Issue.record("Expected bootstrap to restore the Product Account")
      return
    }
    failingStore.unacknowledgedRecoveryKeySaveError =
      ProductAccountSessionTestError.sessionSaveFailed

    #expect(throws: (any Error).self) {
      try session.preserveUnacknowledgedRecoveryKey("published-key")
    }

    #expect(session.unacknowledgedRecoveryKey == nil)
    #expect(
      try failingStore.loadUnacknowledgedRecoveryKey(productAccountId: snapshot.productAccountId)
        == nil)
  }

  @Test
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
    #expect(relaunchedSession.unacknowledgedRecoveryKey == "unacknowledged-key")

    await relaunchedSession.signOut()

    #expect(relaunchedSession.state == .signedIn(snapshot))
    #expect(
      relaunchedSession.signOutErrorMessage
        == ProductAccountSessionError.recoveryNotBackedUp.localizedDescription)

    try relaunchedSession.acknowledgeRecoveryKey(
      "unacknowledged-key",
      productAccountId: snapshot.productAccountId
    )
    #expect(
      try store.loadUnacknowledgedRecoveryKey(productAccountId: snapshot.productAccountId) == nil)
  }

  @Test
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

    #expect(session.unacknowledgedRecoveryKey == "legacy-key")

    await session.signOut()

    #expect(session.state == .signedIn(snapshot))
    #expect(session.unacknowledgedRecoveryKey == "legacy-key")
    #expect(
      session.signOutErrorMessage
        == ProductAccountSessionError.recoveryNotBackedUp.localizedDescription)

    try session.acknowledgeRecoveryKey(
      "legacy-key",
      productAccountId: snapshot.productAccountId
    )
    #expect(session.unacknowledgedRecoveryKey == nil)
    #expect(
      try store.loadUnacknowledgedRecoveryKey(productAccountId: snapshot.productAccountId) == nil)
  }

  @Test
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

    #expect(session.unacknowledgedRecoveryKey == nil)

    try session.preserveUnacknowledgedRecoveryKey("replacement-key")

    #expect(session.unacknowledgedRecoveryKey == "replacement-key")
    #expect(
      try store.loadUnacknowledgedRecoveryKey(productAccountId: snapshot.productAccountId)?
        .recoveryKey == "replacement-key")
  }

  @Test
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

    #expect(session.unacknowledgedRecoveryKey == "newer-key")
    #expect(
      try store.loadUnacknowledgedRecoveryKey(productAccountId: snapshot.productAccountId)?
        .recoveryKey == "newer-key")
  }

  @Test
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

    #expect(session.state == .signedOut)
    #expect(try store.load() == nil)
    #expect(gmailConnectionService.clearedSessions == [snapshot])
    #expect(
      try store.loadPendingTrustedDeviceUnregistrations() == [
        PendingTrustedDeviceUnregistration(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          productAccountId: snapshot.productAccountId,
          trustedDeviceId: snapshot.trustedDeviceId
        )
      ])

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

    #expect(relaunchedSession.state == .signedOut)
    #expect(try store.loadPendingTrustedDeviceUnregistrations().count == 1)
    #expect(productAccountService.unregisteredTrustedDeviceIds == [snapshot.trustedDeviceId])

    await relaunchedSession.signInWithApple()

    #expect(try store.loadPendingTrustedDeviceUnregistrations().isEmpty)
    #expect(
      productAccountService.unregisteredTrustedDeviceIds == [
        snapshot.trustedDeviceId, snapshot.trustedDeviceId,
      ])
  }

  @Test
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

    #expect(session.state == .signedOut)
    #expect(try store.loadPendingTrustedDeviceUnregistrations().count == 1)
    #expect(signInCallCount == 0)
  }

  @Test
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

    #expect(try store.loadPendingTrustedDeviceUnregistrations().isEmpty)
    #expect(
      Set(productAccountService.unregisteredTrustedDeviceIds)
        == Set([first.trustedDeviceId, second.trustedDeviceId]))
  }

  @Test
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

    #expect(session.state == .loading)
    #expect(outboxCleaner.clearedSessions == [snapshot])

    await cleanupGate.release()
    await signOut.value
    #expect(session.state == .signedOut)
  }

  @Test
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
        Issue.record("A concurrent sign-out must not run separate preparation.")
      }
    }
    await fulfillment(of: [secondRequested], timeout: 1)
    await cleanupGate.release()
    await firstSignOut.value
    await secondSignOut.value

    #expect(productAccountService.recoveryCheckCount == 1)
    #expect(productAccountService.unregisteredTrustedDeviceIds == [snapshot.trustedDeviceId])
    #expect(mailboxConnectionService.clearedSessions == [snapshot])
    #expect(session.state == .signedOut)
  }

  @Test
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

    #expect(session.state == .loading)
    #expect(!(session.isCurrent(snapshot)))
    #expect(mailActionViewModel.isPreparingForSignOut)
    await session.signOut()
  }

  @Test
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
      Issue.record("Expected concurrent sign-in to complete")
      return
    }

    #expect(session.state == .signedIn(newSnapshot))
    #expect(try store.load() == newSnapshot)
    #expect(gmailConnectionService.clearedSessions == [newSnapshot])
  }

  @Test
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
      Issue.record("Expected concurrent sign-in to complete")
      return
    }

    #expect(session.state == .signedIn(newSnapshot))
    #expect(try store.load() == newSnapshot)
  }

  @Test
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

    #expect(
      session.state
        == .failed(ProductAccountSessionTestError.gmailCleanupFailed.localizedDescription))
    #expect(try store.load() == snapshot)
    #expect(gmailConnectionService.clearedSessions == [snapshot])
    #expect(productAccountService.unregisteredTrustedDeviceIds.isEmpty)
  }

  @Test
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

    #expect(session.state == .signedIn(snapshot))
    #expect(
      session.signOutErrorMessage
        == ProductAccountSessionTestError.outboxCleanupFailed.localizedDescription)
    #expect(try store.load() == snapshot)
    #expect(try store.loadPendingSignOutProductAccountId() == nil)
    #expect(outboxCleaner.clearedSessions == [snapshot])
    #expect(mailboxConnectionService.clearedSessions.isEmpty)
    #expect(productAccountService.unregisteredTrustedDeviceIds.isEmpty)
    #expect(!(mailActionViewModel.isPreparingForSignOut))
    #expect(
      mailActionViewModel
        === session.sharedMailActionViewModel(
          for: snapshot,
          service: MailboxConnectionRouter()
        ))
  }

  @Test
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

    #expect(
      session.state == .failed(ProductAccountSessionTestError.keyCleanupFailed.localizedDescription)
    )
    #expect(try store.load() == nil)
    #expect(try keyMaterialStore.load(productAccountId: snapshot.productAccountId) != nil)
    #expect(try store.loadPendingSignOutProductAccountId() == snapshot.productAccountId)
  }

  @Test
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

    #expect(pendingAccountIdAtUnregistration == snapshot.productAccountId)
  }

  @Test
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

    #expect(pendingAccountIdAtPushCleanup == snapshot.productAccountId)
    #expect(pendingAccountIdAtMailboxCleanup == snapshot.productAccountId)
  }

  @Test
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

    #expect(pendingAccountIdDuringPreparation == snapshot.productAccountId)
    #expect(clearedOutboxDuringPreparation)
  }

  @Test
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

    #expect(
      session.state
        == .failed(ProductAccountSessionTestError.sessionClearFailed.localizedDescription))
    #expect(try sessionStore.load() == snapshot)
    #expect(try keyMaterialStore.load(productAccountId: snapshot.productAccountId) == material)
    #expect(try sessionStore.loadPendingSignOutProductAccountId() == snapshot.productAccountId)
  }

  @Test
  func testSignOutClearsMailAssistanceBeforeFalliblePreferenceCleanup() async throws {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    let composeStore = TestComposeLocalStateStore()
    composeStore.clearError = ProductAccountSessionTestError.sessionClearFailed
    let mailAssistanceStore = ProductAccountSessionMailAssistanceStore()
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
      composePreferenceLocalStateStore: composeStore,
      mailAssistanceEnablementStore: mailAssistanceStore,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.signOut()

    #expect(mailAssistanceStore.clearedProductAccountIds == [snapshot.productAccountId])
    #expect(
      session.state == .failed(ProductAccountSessionTestError.sessionClearFailed.localizedDescription)
    )
  }

  @Test
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

    #expect(session.state == .signedOut)
    #expect(try sessionStore.load() == nil)
    #expect(try keyMaterialStore.load(productAccountId: snapshot.productAccountId) == nil)
    #expect(try sessionStore.loadPendingSignOutProductAccountId() == nil)
    #expect(pushUnregisterer.sessions == [snapshot])
    #expect(mailboxConnectionService.clearedSessions == [snapshot])
    #expect(outboxCleaner.clearedSessions == [snapshot])
    #expect(productAccountService.unregisteredTrustedDeviceIds == [snapshot.trustedDeviceId])
  }

  @Test
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

    #expect(session.state == .signedOut)
    #expect(try sessionStore.loadPendingTrustedDeviceUnregistrations().isEmpty)
    #expect(try sessionStore.loadPendingSignOutProductAccountId() == nil)
    #expect(try sessionStore.loadPendingDeletedProductAccountId() == nil)
    #expect(productAccountService.unregisteredTrustedDeviceIds.isEmpty)
    #expect(mailboxConnectionService.clearedSessions == [snapshot])
    #expect(outboxCleaner.clearedSessions == [snapshot])
  }

  @Test
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

    #expect(session.state == .signedOut)
    #expect(try sessionStore.loadPendingTrustedDeviceUnregistrations().isEmpty)
    #expect(try sessionStore.loadPendingDeletedProductAccountId() == nil)
    #expect(productAccountService.unregisteredTrustedDeviceIds.isEmpty)
  }

  @Test
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

    #expect(session.state == .signedOut)
    #expect(signInCallCount == 0)
    #expect(try sessionStore.load() == nil)
    #expect(
      try sessionStore.loadPendingTrustedDeviceUnregistrations() == [
        PendingTrustedDeviceUnregistration(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          productAccountId: snapshot.productAccountId,
          trustedDeviceId: snapshot.trustedDeviceId
        )
      ])
    #expect(productAccountService.unregistrationIdentityTokens.isEmpty)
  }

  @Test
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

    #expect(session.state == .signedOut)
    #expect(
      try sessionStore.loadPendingTrustedDeviceUnregistrations() == [
        PendingTrustedDeviceUnregistration(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          productAccountId: snapshot.productAccountId,
          trustedDeviceId: snapshot.trustedDeviceId
        )
      ])
  }

  @Test
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

    #expect(try store.load(productAccountId: "product-account-001") == [firstAttempt])
    #expect(try store.load(productAccountId: "product-account-002") == [secondAttempt])

    try store.clear(productAccountId: "product-account-001")

    #expect(try store.load(productAccountId: "product-account-001") == [])
    #expect(try store.load(productAccountId: "product-account-002") == [secondAttempt])
  }

  @Test
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

    #expect(session.state == .signedIn(snapshot))
    #expect(
      session.signOutErrorMessage
        == ProductAccountSessionTestError.outboxCleanupFailed.localizedDescription)
    #expect(try store.load() == snapshot)
    #expect(try store.loadPendingSignOutProductAccountId() == nil)
    let retainedAttempts = try await outboxService.items(session: snapshot)
    #expect(retainedAttempts.map(\.message.body) == ["Queued private body"])

    outboxStore.clearError = nil
    await session.signOut()

    #expect(session.state == .signedOut)
    #expect(try store.load() == nil)
    let remainingAttempts = try await outboxService.items(session: snapshot)
    #expect(remainingAttempts.isEmpty)
  }

  @Test
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

    #expect(
      session.state
        == .failed(ProductAccountSessionTestError.gmailCleanupFailed.localizedDescription))
    #expect(try store.load() == snapshot)
  }

  @Test
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

    #expect(session.state == .signedOut)
    #expect(sessionStore.didClear)
  }

  @Test
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

    #expect(session.state == .signedOut)
    #expect(sessionStore.didClear)
  }

  @Test
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

    #expect(session.state == .signedOut)
    #expect(try store.load() == nil)
    #expect(gmailConnectionService.clearedSessions == [snapshot])
  }

  @Test
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
      Issue.record("Expected signed-in state")
      return
    }
    #expect(snapshot.productAccountId == ProductAccountConnectResponse.preview.productAccountId)
    #expect(try store.load() == snapshot)
    #expect(gmailConnectionService.clearedSessions == [oldSnapshot])
    #expect(outboxCleaner.suspendedProductAccountIds == [oldSnapshot.productAccountId])
    #expect(outboxCleaner.clearedSessions == [oldSnapshot])
    #expect(pushUnregisterer.sessions == [oldSnapshot])
  }

  @Test
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
      Issue.record("Expected failed state")
      return
    }
    #expect(try sessionStore.load() == oldSnapshot)
    #expect(gmailConnectionService.clearedSessions == [])
    #expect(pushUnregisterer.sessions == [])
  }

  @Test
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
      Issue.record("Expected failed state")
      return
    }
    #expect(try store.load() == oldSnapshot)
    #expect(gmailConnectionService.clearedSessions == [oldSnapshot])
    #expect(outboxCleaner.suspendedProductAccountIds == [oldSnapshot.productAccountId])
    #expect(outboxCleaner.clearedSessions == [oldSnapshot])
    #expect(pushUnregisterer.sessions == [])
  }

  @Test
  func testSignInDoesNotRetainCompletedOutboxCleanupWhenSessionRollbackFails() async throws {
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
      Issue.record("Expected failed state")
      return
    }
    #expect(try sessionStore.load()?.productAccountId == "productAccountFixtureId")
    #expect(try sessionStore.loadPendingOutboxCleanupProductAccountId() == nil)
  }

  @Test
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

    #expect(
      session.state == .failed(ProductAccountSessionError.pendingOutboxCleanup.localizedDescription)
    )
    #expect(try sessionStore.load() == currentSnapshot)
    #expect(
      try sessionStore.loadPendingOutboxCleanupProductAccountId() == "earlierProductAccountId")
    #expect(gmailConnectionService.clearedSessions.isEmpty)
    #expect(productAccountService.materialInitializationIdentityTokens.isEmpty)
    #expect(
      try keyMaterialStore.load(
        productAccountId: ProductAccountConnectResponse.preview.productAccountId
      ) == nil)
  }

  @Test
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

    #expect(
      session.state
        == .failed(
          ProductAccountSessionTestError.outboxCleanupMarkerSaveFailed.localizedDescription))
    #expect(try sessionStore.load() == oldSnapshot)
    #expect(gmailConnectionService.clearedSessions.isEmpty)
    #expect(outboxCleaner.clearedSessions.isEmpty)
  }

  @Test
  func testSignInPreservesPreviousAccountWhenOutboxCleanupFails() async throws {
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

    #expect(
      session.state
        == .failed(ProductAccountSessionTestError.outboxCleanupFailed.localizedDescription))
    #expect(try store.load() == oldSnapshot)
    #expect(gmailConnectionService.clearedSessions.isEmpty)
    #expect(outboxCleaner.clearedSessions == [oldSnapshot])
    #expect(try store.loadPendingOutboxCleanupProductAccountId() == nil)
    #expect(pushUnregisterer.sessions.isEmpty)
  }

  @Test
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
      Issue.record("Expected failed state")
      return
    }
    #expect(try store.load() == snapshot)
  }

  @Test
  func testBootstrapReconnectRequiredClearsTrustedDeviceCredential() async throws {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    let credentialStore = InMemoryTrustedDeviceCredentialStore(
      credentials: [snapshot.trustedDeviceId: "stale-credential"]
    )
    let accountService = RecordingDeletionProductAccountService(response: Self.restorableResponse)
    accountService.connectError = ProductAccountServiceError.trustedDeviceReconnectRequired
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      productAccountService: accountService,
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore,
      trustedDeviceCredentialStore: credentialStore
    )

    await session.bootstrap()

    #expect(
      session.state
        == .failed(ProductAccountServiceError.trustedDeviceReconnectRequired.localizedDescription))
    #expect(try credentialStore.load(trustedDeviceId: snapshot.trustedDeviceId) == nil)
  }

  @Test
  func testSignInReconnectRequiredClearsTrustedDeviceCredential() async throws {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    let credentialStore = InMemoryTrustedDeviceCredentialStore(
      credentials: [snapshot.trustedDeviceId: "stale-credential"]
    )
    let accountService = RecordingDeletionProductAccountService(response: Self.restorableResponse)
    accountService.connectError = ProductAccountServiceError.trustedDeviceReconnectRequired
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      productAccountService: accountService,
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore,
      trustedDeviceCredentialStore: credentialStore
    )

    await session.signInWithApple()

    #expect(
      session.state
        == .failed(ProductAccountServiceError.trustedDeviceReconnectRequired.localizedDescription))
    #expect(try credentialStore.load(trustedDeviceId: snapshot.trustedDeviceId) == nil)
  }

  @Test
  func testExplicitSignInPurgesRevokedSessionAfterTransientBootstrapFailure() async throws {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: snapshot.productAccountId,
      allowCreation: true
    )
    let mailboxConnectionService = RecordingGmailProviderConnecting()
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      productAccountService: TransientRevokedProductAccountService(),
      sessionStore: store,
      mailboxConnectionService: mailboxConnectionService,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.bootstrap()
    #expect(try store.load() == snapshot)

    await session.signInWithApple()

    #expect(session.state == .signedOut)
    #expect(try store.load() == nil)
    #expect(try keyMaterialStore.load(productAccountId: snapshot.productAccountId) == nil)
    #expect(mailboxConnectionService.clearedSession == snapshot)
  }

  @Test
  func testExplicitSignInPreservesExistingSessionWhenAnotherAppleAccountIsRevoked()
    async throws
  {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    let material = try keyMaterialStore.ensureMaterial(
      productAccountId: snapshot.productAccountId,
      allowCreation: true
    )
    let mailboxConnectionService = RecordingGmailProviderConnecting()
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: "another-apple-user",
          identityToken: "another-token"
        )
      ),
      productAccountService: TransientRevokedProductAccountService(),
      sessionStore: store,
      mailboxConnectionService: mailboxConnectionService,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.bootstrap()
    await session.signInWithApple()

    #expect(try store.load() == snapshot)
    #expect(try keyMaterialStore.load(productAccountId: snapshot.productAccountId) == material)
    #expect(mailboxConnectionService.clearedSession == nil)
    #expect(
      session.state
        == .failed(ProductAccountSessionError.differentAppleAccount.localizedDescription))
  }

  @Test
  func testBootstrapPurgesLocalDataWhenTrustedDeviceWasRemotelyRevoked() async throws {
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
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      productAccountService: RevokedDeviceAccountService(),
      sessionStore: store,
      mailboxConnectionService: mailboxConnectionService,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.bootstrap()

    #expect(session.state == .signedOut)
    #expect(try store.load() == nil)
    #expect(try keyMaterialStore.load(productAccountId: snapshot.productAccountId) == nil)
    #expect(mailboxConnectionService.clearedSession == snapshot)
    #expect(try store.loadPendingTrustedDeviceUnregistrations() == [])
  }

  @Test
  func testBackgroundRevocationPurgesPersistedSessionBeforeBootstrap() async throws {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: snapshot.productAccountId,
      allowCreation: true
    )
    let mailboxConnectionService = RecordingGmailProviderConnecting()
    let wakeupDrainer = RecordingGmailPushWakeupDrainer()
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      gmailPushWakeupDrainer: wakeupDrainer,
      productAccountService: PreviewProductAccountService(response: Self.restorableResponse),
      sessionStore: store,
      mailboxConnectionService: mailboxConnectionService,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.handleBackgroundTrustedDeviceRevocation(snapshot)

    #expect(session.state == .signedOut)
    #expect(try store.load() == nil)
    #expect(try keyMaterialStore.load(productAccountId: snapshot.productAccountId) == nil)
    #expect(mailboxConnectionService.clearedSession == snapshot)
    #expect(wakeupDrainer.drainedProductAccountIds == [snapshot.productAccountId])
    #expect(wakeupDrainer.finishedProductAccountIds == [snapshot.productAccountId])
  }

  @Test
  func testBackgroundRevocationWaitsForAccountOperation() async throws {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      productAccountService: PreviewProductAccountService(response: Self.restorableResponse),
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore
    )
    await productAccountRecoveryOperationGate.acquire(
      productAccountId: snapshot.productAccountId
    )

    let revocation = Task { await session.handleBackgroundTrustedDeviceRevocation(snapshot) }
    await waitForRecoveryOperationWaiter(productAccountId: snapshot.productAccountId)

    #expect(try store.load() == snapshot)

    await productAccountRecoveryOperationGate.release(
      productAccountId: snapshot.productAccountId
    )
    await revocation.value
    #expect(try store.load() == nil)
  }

  @Test
  func testForegroundRevalidationPurgesAfterPostConnectRevocation() async throws {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: snapshot.productAccountId,
      allowCreation: true
    )
    let mailboxConnectionService = RecordingGmailProviderConnecting()
    let accountService = RevokedAfterConnectProductAccountService(
      response: ProductAccountConnectResponse(
        accountCreated: false,
        deviceRegistered: false,
        productSyncMaterialInitialized: true,
        productAccountId: snapshot.productAccountId,
        trustedDeviceId: snapshot.trustedDeviceId
      )
    )
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      productAccountService: accountService,
      sessionStore: store,
      mailboxConnectionService: mailboxConnectionService,
      productSyncKeyMaterialStore: keyMaterialStore
    )
    await session.bootstrap()
    guard case .signedIn = session.state else {
      Issue.record("Expected bootstrap to sign in")
      return
    }

    let revalidated = await session.revalidateTrustedDeviceAfterForegrounding()

    #expect(!(revalidated))
    #expect(session.state == .signedOut)
    #expect(try store.load() == nil)
    #expect(try keyMaterialStore.load(productAccountId: snapshot.productAccountId) == nil)
    #expect(mailboxConnectionService.clearedSession == snapshot)
    #expect(try store.loadPendingTrustedDeviceUnregistrations() == [])
  }

  @Test
  func testForegroundRevalidationPreservesSessionAfterTransientConnectFailure() async throws {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    let material = try keyMaterialStore.ensureMaterial(
      productAccountId: snapshot.productAccountId,
      allowCreation: true
    )
    let productAccountService = RecordingProductAccountService(
      response: ProductAccountConnectResponse(
        accountCreated: false,
        deviceRegistered: false,
        productSyncMaterialInitialized: true,
        productAccountId: snapshot.productAccountId,
        trustedDeviceId: snapshot.trustedDeviceId
      )
    )
    productAccountService.connectErrorAfterFirstCall = ConvexClientError.missingConvexURL
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      productAccountService: productAccountService,
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.bootstrap()
    let revalidated = await session.revalidateTrustedDeviceAfterForegrounding()

    #expect(!(revalidated))
    #expect(session.state == .signedIn(snapshot))
    #expect(try store.load() == snapshot)
    #expect(try keyMaterialStore.load(productAccountId: snapshot.productAccountId) == material)
  }

  @Test
  func testTrustedDeviceForegroundRevalidationSurfacesReconnectAndClearsCredential()
    async throws
  {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: snapshot.productAccountId,
      allowCreation: true
    )
    let credentialStore = InMemoryTrustedDeviceCredentialStore(
      credentials: [snapshot.trustedDeviceId: "stale-credential"]
    )
    let productAccountService = RecordingProductAccountService(response: Self.restorableResponse)
    productAccountService.connectErrorAfterFirstCall =
      ProductAccountServiceError.trustedDeviceReconnectRequired
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      productAccountService: productAccountService,
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore,
      trustedDeviceCredentialStore: credentialStore
    )

    await session.bootstrap()
    let revalidated = await session.revalidateTrustedDeviceAfterForegrounding()

    #expect(!(revalidated))
    #expect(
      session.state
        == .failed(ProductAccountServiceError.trustedDeviceReconnectRequired.localizedDescription))
    #expect(try credentialStore.load(trustedDeviceId: snapshot.trustedDeviceId) == nil)
  }

  @Test
  func testRevocationClearsCredentialBeforeFallibleOutboxCleanup() async throws {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: snapshot.productAccountId,
      allowCreation: true
    )
    let credentialStore = InMemoryTrustedDeviceCredentialStore(
      credentials: [snapshot.trustedDeviceId: "revoked-credential"]
    )
    let outboxCleaner = RecordingOutboxDeliveryCleaner()
    outboxCleaner.clearError = ProductAccountSessionTestError.outboxCleanupFailed
    outboxCleaner.clearAction = {
      #expect(throws: Never.self) {
        let credential = try credentialStore.load(trustedDeviceId: snapshot.trustedDeviceId)
        #expect(credential == nil)
      }
    }
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      productAccountService: PreviewProductAccountService(response: Self.restorableResponse),
      sessionStore: store,
      outboxDeliveryService: outboxCleaner,
      productSyncKeyMaterialStore: keyMaterialStore,
      trustedDeviceCredentialStore: credentialStore
    )
    await session.bootstrap()

    await session.handleTrustedDeviceRevocation(snapshot)

    #expect(
      session.state
        == .failed(ProductAccountSessionTestError.outboxCleanupFailed.localizedDescription))
    #expect(try credentialStore.load(trustedDeviceId: snapshot.trustedDeviceId) == nil)
  }

  @Test
  func testForegroundRevalidationAcceptsSameAccountDeviceReregistration() async throws {
    let snapshot = Self.restorableSnapshot
    try store.save(snapshot)
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: snapshot.productAccountId,
      allowCreation: true
    )
    let productAccountService = RecordingProductAccountService(
      response: ProductAccountConnectResponse(
        accountCreated: false,
        deviceRegistered: false,
        productSyncMaterialInitialized: true,
        productAccountId: snapshot.productAccountId,
        trustedDeviceId: snapshot.trustedDeviceId
      )
    )
    productAccountService.responseAfterFirstConnect = ProductAccountConnectResponse(
      accountCreated: false,
      deviceRegistered: true,
      productSyncMaterialInitialized: true,
      productAccountId: snapshot.productAccountId,
      trustedDeviceId: "trusted-device-002"
    )
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          identityToken: snapshot.identityToken
        )
      ),
      productAccountService: productAccountService,
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.bootstrap()
    let revalidated = await session.revalidateTrustedDeviceAfterForegrounding()

    guard case .signedIn(let refreshedSnapshot) = session.state else {
      Issue.record("Expected the re-registered device to remain signed in")
      return
    }
    #expect(revalidated)
    #expect(refreshedSnapshot.productAccountId == snapshot.productAccountId)
    #expect(refreshedSnapshot.trustedDeviceId == "trusted-device-002")
    #expect(try store.load() == refreshedSnapshot)
  }

  @Test
  func testForegroundRevalidationRefreshesAnExpiredIdentityToken() async throws {
    let expiredSnapshot = ProductAccountSessionSnapshot(
      appleUserIdentifier: Self.restorableSnapshot.appleUserIdentifier,
      identityToken: "expired-token",
      identityTokenExpiresAt: .distantPast,
      productAccountId: Self.restorableSnapshot.productAccountId,
      trustedDeviceId: Self.restorableSnapshot.trustedDeviceId
    )
    try store.save(expiredSnapshot)
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: expiredSnapshot.productAccountId,
      allowCreation: true
    )
    let appleSignInService = RecordingForegroundAppleSignInService(
      credential: AppleSignInCredential(
        appleUserIdentifier: expiredSnapshot.appleUserIdentifier,
        identityToken: "fresh-token"
      )
    )
    let productAccountService = RecordingProductAccountService(
      response: ProductAccountConnectResponse(
        accountCreated: false,
        deviceRegistered: false,
        productSyncMaterialInitialized: true,
        productAccountId: expiredSnapshot.productAccountId,
        trustedDeviceId: expiredSnapshot.trustedDeviceId
      )
    )
    let session = ProductAccountSession(
      appleSignInService: appleSignInService,
      productAccountService: productAccountService,
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.bootstrap()
    let revalidated = await session.revalidateTrustedDeviceAfterForegrounding()

    let signInCallCount = await appleSignInService.signInCallCount
    let restoreSessionCallCount = await appleSignInService.restoreSessionCallCount
    #expect(signInCallCount == 1)
    #expect(restoreSessionCallCount == 1)
    #expect(productAccountService.connectIdentityTokens == ["expired-token", "fresh-token"])
    #expect(revalidated)
    #expect(session.isCurrentSessionIdentity(expiredSnapshot))
    #expect(!(session.isCurrent(expiredSnapshot)))
  }

  @Test
  func testRevocationFromAnOlderTokenPurgesTheRefreshedSession() async throws {
    let expiredSnapshot = ProductAccountSessionSnapshot(
      appleUserIdentifier: Self.restorableSnapshot.appleUserIdentifier,
      identityToken: "expired-token",
      identityTokenExpiresAt: .distantPast,
      productAccountId: Self.restorableSnapshot.productAccountId,
      trustedDeviceId: Self.restorableSnapshot.trustedDeviceId
    )
    try store.save(expiredSnapshot)
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: expiredSnapshot.productAccountId,
      allowCreation: true
    )
    let mailboxConnectionService = RecordingGmailProviderConnecting()
    let session = ProductAccountSession(
      appleSignInService: RecordingForegroundAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: expiredSnapshot.appleUserIdentifier,
          identityToken: "fresh-token"
        )
      ),
      productAccountService: RecordingProductAccountService(
        response: ProductAccountConnectResponse(
          accountCreated: false,
          deviceRegistered: false,
          productSyncMaterialInitialized: true,
          productAccountId: expiredSnapshot.productAccountId,
          trustedDeviceId: expiredSnapshot.trustedDeviceId
        )
      ),
      sessionStore: store,
      mailboxConnectionService: mailboxConnectionService,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.bootstrap()
    let revalidated = await session.revalidateTrustedDeviceAfterForegrounding()
    #expect(revalidated)
    #expect(!(session.isCurrent(expiredSnapshot)))

    await session.handleTrustedDeviceRevocation(expiredSnapshot)

    #expect(session.state == .signedOut)
    #expect(try store.load() == nil)
    #expect(mailboxConnectionService.clearedSession == expiredSnapshot)
  }

  @Test
  func testForegroundRevalidationRejectsAnotherAppleAccountBeforeConnecting() async throws {
    let expiredSnapshot = ProductAccountSessionSnapshot(
      appleUserIdentifier: Self.restorableSnapshot.appleUserIdentifier,
      identityToken: "expired-token",
      identityTokenExpiresAt: .distantPast,
      productAccountId: Self.restorableSnapshot.productAccountId,
      trustedDeviceId: Self.restorableSnapshot.trustedDeviceId
    )
    try store.save(expiredSnapshot)
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: expiredSnapshot.productAccountId,
      allowCreation: true
    )
    let appleSignInService = RecordingForegroundAppleSignInService(
      credential: AppleSignInCredential(
        appleUserIdentifier: "another-apple-user",
        identityToken: "another-user-token"
      )
    )
    let productAccountService = RecordingProductAccountService(
      response: ProductAccountConnectResponse(
        accountCreated: false,
        deviceRegistered: false,
        productSyncMaterialInitialized: true,
        productAccountId: expiredSnapshot.productAccountId,
        trustedDeviceId: expiredSnapshot.trustedDeviceId
      )
    )
    let session = ProductAccountSession(
      appleSignInService: appleSignInService,
      productAccountService: productAccountService,
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.bootstrap()
    let revalidated = await session.revalidateTrustedDeviceAfterForegrounding()

    #expect(!(revalidated))
    #expect(productAccountService.connectIdentityTokens == ["expired-token"])
    guard case .signedIn(let currentSnapshot) = session.state else {
      Issue.record("Expected the original Product Account session to remain signed in")
      return
    }
    #expect(currentSnapshot.appleUserIdentifier == expiredSnapshot.appleUserIdentifier)
    #expect(currentSnapshot.identityToken != "another-user-token")
  }

  @Test
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
      #expect(
        freshnessStore.load(
          productAccountId: snapshot.productAccountId,
          connectionId: connectionId
        ) != nil)
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

    #expect(session.state == .signedOut)
    #expect(try store.load() == nil)
    #expect(try keyMaterialStore.load(productAccountId: snapshot.productAccountId) == nil)
    #expect(try store.loadPendingSignOutProductAccountId() == nil)
    #expect(
      try store.loadUnacknowledgedRecoveryKey(productAccountId: snapshot.productAccountId) == nil)
    #expect(
      try store.loadPendingTrustedDeviceUnregistrations() == [
        PendingTrustedDeviceUnregistration(
          appleUserIdentifier: snapshot.appleUserIdentifier,
          productAccountId: snapshot.productAccountId,
          trustedDeviceId: snapshot.trustedDeviceId
        )
      ])
    #expect(gmailConnectionService.clearedSession == snapshot)
    #expect(outboxCleaner.clearedSessions == [snapshot])
    #expect(pushUnregisterer.sessions == [])
    #expect(stateDuringCleanup == .loading)
    #expect(
      freshnessStore.load(
        productAccountId: snapshot.productAccountId,
        connectionId: connectionId
      ) == nil)
    #expect(bodyPrefetchWasCancelled)
    #expect(fallbackStore.clearedProductAccountIds == [snapshot.productAccountId])
    #expect(pushWakeupDrainer.drainedProductAccountIds == [snapshot.productAccountId])
    #expect(cleanupEvents == ["push", "mailbox"])
    #expect(notificationClearer.clearedProductAccountIds == [snapshot.productAccountId])
    #expect(pushWakeupDrainer.finishedProductAccountIds == [snapshot.productAccountId])
  }

  @Test
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

    #expect(
      session.state
        == .failed(ProductAccountSessionTestError.outboxCleanupFailed.localizedDescription))
    #expect(try store.load() == snapshot)
    #expect(try keyMaterialStore.load(productAccountId: snapshot.productAccountId) != nil)
    #expect(try store.loadPendingSignOutProductAccountId() == snapshot.productAccountId)
    #expect(outboxCleaner.clearedSessions == [snapshot])
    #expect(mailboxConnectionService.clearedSessions.isEmpty)
    #expect(try store.loadPendingTrustedDeviceUnregistrations().isEmpty)
  }

  @Test
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

    #expect(session.state == .signedOut)
    #expect(countingStore.loadCount == 1)
  }

  @Test
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
      Issue.record("Expected the shared bootstrap to finish for the surviving window.")
      return
    }
    #expect(countingStore.loadCount == 1)
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testBootstrapRetainsRevokedSessionUntilMailboxCleanupSucceeds() async throws {
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

    #expect(
      session.state
        == .failed(ProductAccountSessionTestError.gmailCleanupFailed.localizedDescription))
    #expect(try store.load() == snapshot)
    #expect(try keyMaterialStore.load(productAccountId: snapshot.productAccountId) != nil)
    #expect(try store.loadPendingSignOutProductAccountId() == snapshot.productAccountId)
    #expect(
      try store.loadUnacknowledgedRecoveryKey(productAccountId: snapshot.productAccountId)
        == UnacknowledgedRecoveryKey(
          recoveryKey: "unacknowledged-key",
          recoveryWrappedAccountKey: nil
        ))
    #expect(try store.loadPendingTrustedDeviceUnregistrations().isEmpty)
    #expect(session.unacknowledgedRecoveryKey == nil)
    #expect(gmailConnectionService.clearedSession == snapshot)

    gmailConnectionService.clearError = nil
    let retryingSession = ProductAccountSession(
      appleSignInService: RevokedAppleSignInService(),
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: store,
      mailboxConnectionService: gmailConnectionService,
      productSyncKeyMaterialStore: keyMaterialStore
    )
    await retryingSession.bootstrap()

    #expect(retryingSession.state == .signedOut)
    #expect(try store.load() == nil)
    #expect(try keyMaterialStore.load(productAccountId: snapshot.productAccountId) == nil)
    #expect(try store.loadPendingSignOutProductAccountId() == nil)
  }

  @Test
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
      Issue.record("Expected signed-in state")
      return
    }
    #expect(snapshot.productAccountId == ProductAccountConnectResponse.preview.productAccountId)
    #expect(try store.load() == snapshot)
    #expect(gmailConnectionService.clearedSessions == [oldSnapshot])
    #expect(outboxCleaner.clearedSessions == [oldSnapshot])
    #expect(pushUnregisterer.sessions == [oldSnapshot])
  }

  @Test
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
      Issue.record("Expected failed state")
      return
    }
    #expect(try store.load() == oldSnapshot)
    #expect(gmailConnectionService.clearedSessions == [oldSnapshot])
    #expect(outboxCleaner.clearedSessions == [oldSnapshot])
    #expect(pushUnregisterer.sessions == [])
  }

  @Test
  func testBootstrapPreservesPreviousAccountWhenOutboxCleanupFails() async throws {
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

    #expect(
      session.state
        == .failed(ProductAccountSessionTestError.outboxCleanupFailed.localizedDescription))
    #expect(try store.load() == oldSnapshot)
    #expect(gmailConnectionService.clearedSessions.isEmpty)
    #expect(outboxCleaner.clearedSessions == [oldSnapshot])
    #expect(try store.loadPendingOutboxCleanupProductAccountId() == nil)
    #expect(pushUnregisterer.sessions.isEmpty)
  }

  @Test
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

    #expect(
      session.state
        == .failed(
          ProductAccountSessionTestError.outboxCleanupMarkerSaveFailed.localizedDescription))
    #expect(try sessionStore.load() == oldSnapshot)
    #expect(gmailConnectionService.clearedSessions.isEmpty)
    #expect(outboxCleaner.clearedSessions.isEmpty)
    #expect(pushUnregisterer.sessions.isEmpty)
  }

  @Test
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

    #expect(
      session.state == .failed(ProductAccountSessionError.pendingOutboxCleanup.localizedDescription)
    )
    #expect(try sessionStore.load() == currentSnapshot)
    #expect(
      try sessionStore.loadPendingOutboxCleanupProductAccountId() == "earlierProductAccountId")
    #expect(productAccountService.materialInitializationIdentityTokens.isEmpty)
    #expect(
      try keyMaterialStore.load(
        productAccountId: ProductAccountConnectResponse.preview.productAccountId
      ) == nil)
  }

  @Test
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

    #expect(
      session.state
        == .failed(ProductAccountSessionTestError.sessionLoadFailed.localizedDescription))
    #expect(
      try sessionStore.loadPendingOutboxCleanupProductAccountId() == snapshot.productAccountId)
    #expect(outboxCleaner.clearedProductAccountIds.isEmpty)
  }

  @Test
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

    #expect(outboxCleaner.clearedProductAccountIds == ["retired-product-account"])
    #expect(try store.loadPendingOutboxCleanupProductAccountId() == nil)
  }

  @Test
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

    #expect(session.state == .signedIn(snapshot))
    #expect(outboxCleaner.clearedProductAccountIds.isEmpty)
    #expect(try store.loadPendingOutboxCleanupProductAccountId() == nil)
  }

  @Test
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

    #expect(session.state == .signedIn(snapshot))
    #expect(outboxCleaner.clearedProductAccountIds == ["retired-product-account"])
    #expect(try store.loadPendingOutboxCleanupProductAccountId() == "retired-product-account")
  }

  @Test
  func testBootstrapCompletesPendingSignOutBeforeRetiredOutboxCleanup() async throws {
    let snapshot = Self.restorableSnapshot
    let sessionStore = ControllableProductAccountSessionStore(snapshot: snapshot)
    try sessionStore.savePendingSignOutProductAccountId(snapshot.productAccountId)
    try sessionStore.savePendingOutboxCleanupProductAccountId("retired-product-account")
    let freshnessKey = "mailbox-sync-success.\(snapshot.productAccountId).gmail:account-001"
    UserDefaults.standard.set(Date(), forKey: freshnessKey)
    defer { UserDefaults.standard.removeObject(forKey: freshnessKey) }
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

    #expect(try sessionStore.load() == nil)
    #expect(try sessionStore.loadPendingSignOutProductAccountId() == nil)
    #expect(UserDefaults.standard.object(forKey: freshnessKey) == nil)
    #expect(try keyMaterialStore.load(productAccountId: snapshot.productAccountId) == nil)
    #expect(outboxCleaner.clearedSessions == [snapshot])
    #expect(outboxCleaner.clearedProductAccountIds == ["retired-product-account"])
    #expect(
      try sessionStore.loadPendingOutboxCleanupProductAccountId() == "retired-product-account")
    #expect(session.state == .signedOut)
  }

  @Test
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
      #expect(UserDefaults.standard.object(forKey: freshnessKey) != nil)
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

    #expect(UserDefaults.standard.object(forKey: freshnessKey) == nil)
    #expect(session.state == .signedOut)
  }

  @Test
  func testExistingProductAccountWithoutLocalSyncMaterialRequiresRecovery() async throws {
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
      Issue.record("Expected failed state")
      return
    }
    #expect(message == ProductSyncKeyMaterialStoreError.recoveryRequired.localizedDescription)
    #expect(
      try keyMaterialStore.load(
        productAccountId: ProductAccountConnectResponse.resumed.productAccountId
      ) == nil)
  }

  @Test
  func testSwitchingAccountsWhileRecoveryIsPendingUnregistersAbandonedDevice() async throws {
    let accountAResponse = ProductAccountConnectResponse.resumed
    let accountBResponse = ProductAccountConnectResponse(
      accountCreated: true,
      deviceRegistered: true,
      productSyncMaterialInitialized: false,
      productAccountId: "product-account-b",
      trustedDeviceId: "trusted-device-b"
    )
    let recoveryMaterial = try ProductSyncKeyMaterial.create()
    let productAccountService = RecordingProductAccountService(response: accountAResponse)
    productAccountService.recoveryMaterial = EncryptedProductSyncPayload(
      encryptedPayload: recoveryMaterial.recoveryWrappedAccountKey,
      payloadIdentifier: AccountAndDevicesService.recoveryPayloadIdentifier,
      updatedAt: 1
    )
    productAccountService.responseAfterFirstConnect = accountBResponse
    let session = ProductAccountSession(
      appleSignInService: SequencedAppleSignInService(
        credentials: [
          AppleSignInCredential(
            appleUserIdentifier: "apple-user-a",
            identityToken: "token-a"
          ),
          AppleSignInCredential(
            appleUserIdentifier: "apple-user-b",
            identityToken: "token-b"
          ),
        ]
      ),
      productAccountService: productAccountService,
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.signInWithApple()
    #expect(session.requiresProductSyncRecovery)

    await session.signInWithApple()

    guard case .signedIn(let snapshot) = session.state else {
      Issue.record("Expected account B to sign in")
      return
    }
    #expect(snapshot.productAccountId == accountBResponse.productAccountId)
    #expect(!(session.requiresProductSyncRecovery))
    #expect(productAccountService.unregistrationIdentityTokens == ["token-a"])
    #expect(
      productAccountService.unregisteredTrustedDeviceIds == [accountAResponse.trustedDeviceId])
    #expect(try store.loadPendingTrustedDeviceUnregistrations().isEmpty)
  }

  @Test
  func testSwitchingAccountsRetainsAbandonedDeviceRetryWhenUnregistrationFails()
    async throws
  {
    let accountAResponse = ProductAccountConnectResponse.resumed
    let accountBResponse = ProductAccountConnectResponse(
      accountCreated: true,
      deviceRegistered: true,
      productSyncMaterialInitialized: false,
      productAccountId: "product-account-b",
      trustedDeviceId: "trusted-device-b"
    )
    let recoveryMaterial = try ProductSyncKeyMaterial.create()
    let productAccountService = RecordingProductAccountService(response: accountAResponse)
    productAccountService.recoveryMaterial = EncryptedProductSyncPayload(
      encryptedPayload: recoveryMaterial.recoveryWrappedAccountKey,
      payloadIdentifier: AccountAndDevicesService.recoveryPayloadIdentifier,
      updatedAt: 1
    )
    productAccountService.responseAfterFirstConnect = accountBResponse
    let session = ProductAccountSession(
      appleSignInService: SequencedAppleSignInService(
        credentials: [
          AppleSignInCredential(
            appleUserIdentifier: "apple-user-a",
            identityToken: "token-a"
          ),
          AppleSignInCredential(
            appleUserIdentifier: "apple-user-b",
            identityToken: "token-b"
          ),
        ]
      ),
      productAccountService: productAccountService,
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.signInWithApple()
    productAccountService.unregisterError =
      ProductAccountSessionTestError.trustedDeviceUnregistrationFailed

    await session.signInWithApple()

    guard case .signedIn(let snapshot) = session.state else {
      Issue.record("Expected account B to sign in")
      return
    }
    #expect(snapshot.productAccountId == accountBResponse.productAccountId)
    #expect(
      try store.loadPendingTrustedDeviceUnregistrations() == [
        PendingTrustedDeviceUnregistration(
          appleUserIdentifier: "apple-user-a",
          productAccountId: accountAResponse.productAccountId,
          trustedDeviceId: accountAResponse.trustedDeviceId
        )
      ])
  }

  @Test
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

    #expect(session.requiresProductSyncRecovery)
    guard case .failed = session.state else {
      Issue.record("Expected Recovery Key prompt state")
      return
    }

    await session.restoreProductSyncMaterial(recoveryKey: " \n\(original.recoveryKey.rawValue)\t")

    guard case .signedIn(let snapshot) = session.state else {
      Issue.record("Expected signed-in state")
      return
    }
    #expect(!(session.requiresProductSyncRecovery))
    #expect(snapshot.productAccountId == ProductAccountConnectResponse.resumed.productAccountId)
    #expect(
      try keyMaterialStore.load(productAccountId: snapshot.productAccountId)?.accountKeyData
        == original.accountKeyData)
    #expect(productAccountService.materialInitializationIdentityTokens == ["fresh-token"])
    #expect(productAccountService.recoveryMaterialIdentityTokens == ["stale-token", "fresh-token"])
  }

  @Test
  func testRestartedSignInClearsPendingRecoveryWhenTrustedDeviceWasRevoked() async throws {
    let session = try makeRecoveryPendingSession(
      reconnectError: ProductAccountServiceError.trustedDeviceRevoked
    )
    await session.signInWithApple()
    #expect(session.requiresProductSyncRecovery)

    await session.signInWithApple()

    #expect(session.state == .signedOut)
    #expect(!(session.requiresProductSyncRecovery))
  }

  @Test
  func testRestartedSignInClearsPendingRecoveryWhenProductAccountWasDeleted() async throws {
    let session = try makeRecoveryPendingSession(
      reconnectError: ProductAccountServiceError.productAccountDeleted
    )
    await session.signInWithApple()
    #expect(session.requiresProductSyncRecovery)

    await session.signInWithApple()

    #expect(
      session.state
        == .failed(ProductAccountServiceError.productAccountDeleted.localizedDescription))
    #expect(!(session.requiresProductSyncRecovery))
  }

  @Test
  func testRestartedSignInRetainsPendingRecoveryAfterTransientConnectFailure() async throws {
    let session = try makeRecoveryPendingSession(
      reconnectError: ConvexClientError.missingConvexURL
    )
    await session.signInWithApple()
    #expect(session.requiresProductSyncRecovery)

    await session.signInWithApple()

    #expect(session.state == .failed(ConvexClientError.missingConvexURL.localizedDescription))
    #expect(session.requiresProductSyncRecovery)
  }

  @Test
  func testDifferentAccountRevocationRetainsPendingRecovery() async throws {
    let session = try makeRecoveryPendingSession(
      reconnectError: ProductAccountServiceError.trustedDeviceRevoked,
      retryAppleUserIdentifier: "apple-user-002"
    )
    await session.signInWithApple()
    #expect(session.requiresProductSyncRecovery)

    await session.signInWithApple()

    #expect(session.state == .signedOut)
    #expect(session.requiresProductSyncRecovery)
  }

  @Test
  func testDifferentAccountDeletionRetainsPendingRecovery() async throws {
    let session = try makeRecoveryPendingSession(
      reconnectError: ProductAccountServiceError.productAccountDeleted,
      retryAppleUserIdentifier: "apple-user-002"
    )
    await session.signInWithApple()
    #expect(session.requiresProductSyncRecovery)

    await session.signInWithApple()

    #expect(
      session.state
        == .failed(ProductAccountServiceError.productAccountDeleted.localizedDescription))
    #expect(session.requiresProductSyncRecovery)
  }

  @Test
  func testRecoveryKeyRestorePurgesSessionWhenTrustedDeviceWasRevoked() async throws {
    let snapshot = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "stale-token",
      productAccountId: ProductAccountConnectResponse.resumed.productAccountId,
      trustedDeviceId: ProductAccountConnectResponse.resumed.trustedDeviceId
    )
    try store.save(snapshot)
    let original = try ProductSyncKeyMaterial.create(
      accountKeyData: Data(repeating: 41, count: ProductSyncKeyMaterial.keyByteCount),
      recoveryKeyData: Data(repeating: 42, count: ProductSyncKeyMaterial.keyByteCount)
    )
    let productAccountService = RecordingProductAccountService(response: .resumed)
    productAccountService.recoveryMaterial = EncryptedProductSyncPayload(
      encryptedPayload: original.recoveryWrappedAccountKey,
      payloadIdentifier: AccountAndDevicesService.recoveryPayloadIdentifier,
      updatedAt: 1
    )
    let mailboxConnectionService = RecordingGmailProviderConnecting()
    let session = ProductAccountSession(
      appleSignInService: SequencedAppleSignInService(
        credentials: [
          AppleSignInCredential(
            appleUserIdentifier: snapshot.appleUserIdentifier,
            identityToken: snapshot.identityToken
          ),
          AppleSignInCredential(
            appleUserIdentifier: snapshot.appleUserIdentifier,
            identityToken: "fresh-token"
          ),
        ]
      ),
      productAccountService: productAccountService,
      sessionStore: store,
      mailboxConnectionService: mailboxConnectionService,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.bootstrap()
    #expect(session.requiresProductSyncRecovery)
    productAccountService.recoveryMaterialError =
      ProductAccountServiceError.trustedDeviceRevoked

    await session.restoreProductSyncMaterial(recoveryKey: original.recoveryKey.rawValue)

    #expect(session.state == .signedOut)
    #expect(!(session.requiresProductSyncRecovery))
    #expect(try store.load() == nil)
    #expect(mailboxConnectionService.clearedSession == snapshot)
  }

  @Test
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

    #expect(session.state == .signedOut)
    #expect(!(session.requiresProductSyncRecovery))
    #expect(try store.load() == nil)
  }

  @Test
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
      Issue.record("Expected restarted sign-in to complete after recovery")
      return
    }
    #expect(snapshot.identityToken == "restart-token")
    #expect(!(session.requiresProductSyncRecovery))
  }

  @Test
  func testSameDeviceIncompleteInitialBootstrapCreatesMissingMaterial() async throws {
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
      Issue.record("Expected signed-in state")
      return
    }
    #expect(snapshot.productAccountId == response.productAccountId)
    #expect(try keyMaterialStore.load(productAccountId: response.productAccountId) != nil)
  }

  @Test
  func testReturningRegisteredDeviceWithInitializedSyncMaterialRequiresRecovery() async throws {
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
      Issue.record("Expected failed state")
      return
    }
    #expect(message == ProductSyncKeyMaterialStoreError.recoveryRequired.localizedDescription)
    #expect(try keyMaterialStore.load(productAccountId: response.productAccountId) == nil)
  }

  @Test
  func testNewDeviceForUninitializedAccountRequiresRecovery() async throws {
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
      Issue.record("Expected failed state")
      return
    }
    #expect(message == ProductSyncKeyMaterialStoreError.recoveryRequired.localizedDescription)
    #expect(try keyMaterialStore.load(productAccountId: response.productAccountId) == nil)
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
    trustedDeviceId _: String,
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

private final class TransientRevokedProductAccountService: ProductAccountConnecting {
  private var connectCallCount = 0

  func connect(identityToken _: String) async throws -> ProductAccountConnectResponse {
    defer { connectCallCount += 1 }
    if connectCallCount == 0 {
      throw ConvexClientError.missingConvexURL
    }
    throw ProductAccountServiceError.trustedDeviceRevoked
  }

  func markProductSyncMaterialInitialized(
    identityToken _: String,
    trustedDeviceId _: String
  ) async throws -> ProductSyncMaterialInitializedResponse {
    throw ProductAccountServiceError.trustedDeviceRevoked
  }

  func productSyncRecoveryIsBackedUp(
    identityToken _: String,
    trustedDeviceId _: String,
    expectedRecoveryWrappedAccountKey _: ProductSyncEncryptedPayload?
  ) async throws -> Bool {
    false
  }

  func unregisterTrustedDevice(
    identityToken _: String,
    trustedDeviceId _: String
  ) async throws -> TrustedDeviceUnregistrationResponse {
    TrustedDeviceUnregistrationResponse(registered: false)
  }
}

private struct RevokedDeviceAccountService: ProductAccountConnecting {
  func connect(identityToken _: String) async throws -> ProductAccountConnectResponse {
    throw ProductAccountServiceError.trustedDeviceRevoked
  }

  func markProductSyncMaterialInitialized(
    identityToken _: String,
    trustedDeviceId _: String
  ) async throws -> ProductSyncMaterialInitializedResponse {
    throw ProductAccountServiceError.trustedDeviceRevoked
  }

  func productSyncRecoveryIsBackedUp(
    identityToken _: String,
    trustedDeviceId _: String,
    expectedRecoveryWrappedAccountKey _: ProductSyncEncryptedPayload?
  ) async throws -> Bool {
    false
  }

  func unregisterTrustedDevice(
    identityToken _: String,
    trustedDeviceId _: String
  ) async throws -> TrustedDeviceUnregistrationResponse {
    TrustedDeviceUnregistrationResponse(registered: false)
  }
}

private final class RevokedAfterConnectProductAccountService: ProductAccountConnecting {
  private var reconciliationCallCount = 0
  private let response: ProductAccountConnectResponse

  init(response: ProductAccountConnectResponse) {
    self.response = response
  }

  func connect(identityToken _: String) async throws -> ProductAccountConnectResponse {
    response
  }

  func reconcileProductSyncKeyRotation(
    identityToken _: String,
    productAccountId _: String,
    trustedDeviceId _: String
  ) async throws -> ProductSyncKeyRotationResponse? {
    defer { reconciliationCallCount += 1 }
    if reconciliationCallCount > 0 {
      throw ProductAccountServiceError.trustedDeviceRevoked
    }
    return nil
  }

  func markProductSyncMaterialInitialized(
    identityToken _: String,
    trustedDeviceId _: String
  ) async throws -> ProductSyncMaterialInitializedResponse {
    ProductSyncMaterialInitializedResponse(productSyncMaterialInitialized: true)
  }

  func productSyncRecoveryIsBackedUp(
    identityToken _: String,
    trustedDeviceId _: String,
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

private final class RecordingNotificationClearer:
  LegacyUserNotificationMigrating, UserNotificationClearing
{
  private(set) var clearedProductAccountIds: [String] = []
  private(set) var events: [String] = []
  private(set) var migratedGmailProviderAccountIdentifiers: [Set<String>] = []
  private(set) var migratedProductAccountIds: [String] = []

  func clear(productAccountId: String) {
    clearedProductAccountIds.append(productAccountId)
    events.append("clear:\(productAccountId)")
  }

  func migrateLegacyIdentifiers(
    productAccountId: String,
    gmailProviderAccountIdentifiers: Set<String>
  ) async {
    migratedProductAccountIds.append(productAccountId)
    migratedGmailProviderAccountIdentifiers.append(gmailProviderAccountIdentifiers)
    events.append("migrate:\(productAccountId)")
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

private actor RecordingForegroundAppleSignInService: AppleSignInPerforming {
  private(set) var restoreSessionCallCount = 0
  private(set) var signInCallCount = 0
  let credential: AppleSignInCredential

  init(credential: AppleSignInCredential) {
    self.credential = credential
  }

  func signIn() async throws -> AppleSignInCredential {
    signInCallCount += 1
    return credential
  }

  func restoreSession(
    snapshot: ProductAccountSessionSnapshot
  ) async throws -> AppleSignInCredential {
    restoreSessionCallCount += 1
    return AppleSignInCredential(
      appleUserIdentifier: snapshot.appleUserIdentifier,
      identityToken: snapshot.identityToken
    )
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
    trustedDeviceId _: String,
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

private struct FailingConnectionIdEWSAuthorizationStore: EWSAuthorizationPersisting {
  func clear(productAccountId _: String, connectionId _: MailboxConnectionId) throws {}
  func clearAll(productAccountId _: String) throws {}
  func connectionIds(productAccountId _: String) throws -> [MailboxConnectionId] {
    throw ProductAccountSessionTestError.sessionLoadFailed
  }
  func load(
    productAccountId _: String,
    connectionId _: MailboxConnectionId
  ) throws -> DeviceLocalEWSAuthorization? { nil }
  func save(_: DeviceLocalEWSAuthorization, productAccountId _: String) throws {}
}

private struct StubGenericMailAuthStore: GenericMailAuthorizationPersisting {
  let connectionIds: [MailboxConnectionId]

  func clearAll(productAccountId _: ProductAccountId) throws {}
  func connectionIds(productAccountId _: ProductAccountId) throws -> [MailboxConnectionId] {
    connectionIds
  }
  func load(
    productAccountId _: ProductAccountId,
    emailAddress _: String
  ) throws -> DeviceLocalGenericMailAuthorization? { nil }
  func load(
    productAccountId _: ProductAccountId,
    connectionId _: MailboxConnectionId
  ) throws -> DeviceLocalGenericMailAuthorization? { nil }
  func remove(
    productAccountId _: ProductAccountId,
    connectionId _: MailboxConnectionId
  ) throws {}
  func save(
    _: DeviceLocalGenericMailAuthorization,
    productAccountId _: ProductAccountId
  ) throws {}
}

private final class RecordingProductAccountService: ProductAccountConnecting {
  var connectIdentityTokens: [String] = []
  var connectErrorAfterFirstCall: Error?
  var materialInitializationIdentityTokens: [String] = []
  var recoveryBackedUp = true
  var recoveryCheckCount = 0
  var recoveryCheckExpectedWrappedAccountKeys: [ProductSyncEncryptedPayload?] = []
  var recoveryCheckIdentityTokens: [String] = []
  var recoveryCheckAction: (() -> Void)?
  var recoveryMaterial: EncryptedProductSyncPayload?
  var recoveryMaterialError: Error?
  var recoveryMaterialIdentityTokens: [String] = []
  let response: ProductAccountConnectResponse
  var responseAfterFirstConnect: ProductAccountConnectResponse?
  var rotationResponse: ProductSyncKeyRotationResponse?
  var unregisterError: Error?
  var unregistrationAction: (() -> Void)?
  var unregistrationIdentityTokens: [String] = []
  var unregisteredTrustedDeviceIds: [String] = []

  init(response: ProductAccountConnectResponse) {
    self.response = response
  }

  func connect(identityToken: String) async throws -> ProductAccountConnectResponse {
    connectIdentityTokens.append(identityToken)
    if connectIdentityTokens.count > 1 {
      if let connectErrorAfterFirstCall {
        throw connectErrorAfterFirstCall
      }
      if let responseAfterFirstConnect {
        return responseAfterFirstConnect
      }
    }
    return response
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
    trustedDeviceId _: String,
    expectedRecoveryWrappedAccountKey: ProductSyncEncryptedPayload?
  ) async throws -> Bool {
    recoveryCheckCount += 1
    recoveryCheckAction?()
    recoveryCheckIdentityTokens.append(identityToken)
    recoveryCheckExpectedWrappedAccountKeys.append(expectedRecoveryWrappedAccountKey)
    return recoveryBackedUp
  }

  func productSyncRecoveryMaterial(
    identityToken: String,
    trustedDeviceId _: String
  ) async throws -> EncryptedProductSyncPayload? {
    recoveryMaterialIdentityTokens.append(identityToken)
    if let recoveryMaterialError { throw recoveryMaterialError }
    return recoveryMaterial
  }

  func reconcileProductSyncKeyRotation(
    identityToken _: String,
    productAccountId _: String,
    trustedDeviceId _: String
  ) async throws -> ProductSyncKeyRotationResponse? {
    rotationResponse
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
  var clearAction: (() throws -> Void)?
  var clearError: Error?
  var productAccountIdClearError: Error?
  private(set) var clearedSessions: [ProductAccountSessionSnapshot] = []
  private(set) var clearedProductAccountIds: [String] = []
  private(set) var suspendedProductAccountIds: [String] = []

  func clear(session: ProductAccountSessionSnapshot) async throws {
    clearedSessions.append(session)
    try clearAction?()
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

private final class TestComposeLocalStateStore:
  ComposePreferenceLocalStatePersisting
{
  var clearError: Error?
  private var states: [String: ComposePreferenceLocalState] = [:]

  func clear(productAccountId: String) throws {
    if let clearError { throw clearError }
    states[productAccountId] = nil
  }

  func load(productAccountId: String) throws -> ComposePreferenceLocalState? {
    states[productAccountId]
  }

  func save(_ state: ComposePreferenceLocalState, productAccountId: String) throws {
    states[productAccountId] = state
  }
}

private final class ProductAccountSessionMailAssistanceStore:
  MailAssistanceEnablementPersisting
{
  private(set) var clearedProductAccountIds: [String] = []

  func clear(productAccountId: String) {
    clearedProductAccountIds.append(productAccountId)
  }

  func isEnabled(productAccountId _: String, profileId _: MailProfileId) -> Bool {
    false
  }

  func setEnabled(
    _: Bool,
    productAccountId _: String,
    profileId _: MailProfileId
  ) {}
}

private struct TestComposeSyncService: ComposePreferenceSyncing {
  func loadPreferences(
    session _: ProductAccountSessionSnapshot
  ) async throws -> ComposePreferenceSyncSnapshot? {
    nil
  }

  func savePreferences(
    _ preferences: ComposePreferences,
    expectedUpdatedAt _: Int64?,
    session _: ProductAccountSessionSnapshot
  ) async throws -> ComposePreferenceConditionalSaveResult {
    .committed(ComposePreferenceSyncSnapshot(preferences: preferences, updatedAt: 1))
  }
}

private final class TestInboxLocalStateStore: InboxPreferenceLocalStatePersisting {
  private var states: [String: InboxPreferenceLocalState] = [:]

  func clear(productAccountId: String) throws {
    states[productAccountId] = nil
  }

  func load(productAccountId: String) throws -> InboxPreferenceLocalState? {
    states[productAccountId]
  }

  func save(_ state: InboxPreferenceLocalState, productAccountId: String) throws {
    states[productAccountId] = state
  }
}

private struct TestInboxSyncService: InboxPreferenceSyncing {
  func loadPreferences(
    session _: ProductAccountSessionSnapshot
  ) async throws -> InboxPreferenceSyncSnapshot? {
    nil
  }

  func savePreferences(
    _ preferences: InboxPreferences,
    expectedUpdatedAt _: Int64?,
    session _: ProductAccountSessionSnapshot
  ) async throws -> InboxPreferenceConditionalSaveResult {
    .committed(InboxPreferenceSyncSnapshot(preferences: preferences, updatedAt: 1))
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
