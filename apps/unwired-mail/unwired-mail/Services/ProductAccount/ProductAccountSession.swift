import Foundation
import Observation

// swiftlint:disable file_length

private let signOutTokenValidityMargin: TimeInterval = 5 * 60

protocol ProductSyncCacheClearing {
  func clear(productAccountId: String) throws
}

protocol MailboxConnectionIdLoading {
  func loadConnectionIds(session: ProductAccountSessionSnapshot) async throws
    -> [MailboxConnectionId]
}

struct ProductAccountMailboxConnectionIdLoader: MailboxConnectionIdLoading {
  private let snapshotLoader: MailboxConnectionSnapshotLoading
  private let deviceLocalLoader: MailboxConnectionIdLoading

  init(
    snapshotLoader: MailboxConnectionSnapshotLoading = MailboxConnectionRouter(),
    deviceLocalLoader: MailboxConnectionIdLoading = DeviceLocalMailboxConnectionIdLoader()
  ) {
    self.snapshotLoader = snapshotLoader
    self.deviceLocalLoader = deviceLocalLoader
  }

  func loadConnectionIds(session: ProductAccountSessionSnapshot) async throws
    -> [MailboxConnectionId]
  {
    var connectionIds = Set<MailboxConnectionId>()
    do {
      connectionIds.formUnion(try await deviceLocalLoader.loadConnectionIds(session: session))
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      // Remote snapshots remain useful when device-local provider loading is unavailable.
    }
    do {
      let snapshot = try await snapshotLoader.loadConnectionSnapshot(session: session)
      connectionIds.formUnion(snapshot.connections.map(\.id))
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      // Device-local manifests remain authoritative when provider loading is unavailable.
    }
    return connectionIds.sorted { $0.rawValue < $1.rawValue }
  }
}

struct DeviceLocalMailboxConnectionIdLoader: MailboxConnectionIdLoading {
  private let exchangeWebServicesStore: EWSAuthorizationPersisting
  private let genericMailStore: GenericMailAuthorizationPersisting
  private let gmailStore: GmailProviderTokenPersisting
  private let microsoftGraphStore: MicrosoftGraphAuthorizationPersisting

  init(
    exchangeWebServicesStore: EWSAuthorizationPersisting = KeychainEWSAuthorizationStore(),
    genericMailStore: GenericMailAuthorizationPersisting =
      KeychainGenericMailAuthorizationStore(),
    gmailStore: GmailProviderTokenPersisting = KeychainGmailProviderTokenStore(),
    microsoftGraphStore: MicrosoftGraphAuthorizationPersisting =
      KeychainMicrosoftGraphAuthorizationStore()
  ) {
    self.exchangeWebServicesStore = exchangeWebServicesStore
    self.genericMailStore = genericMailStore
    self.gmailStore = gmailStore
    self.microsoftGraphStore = microsoftGraphStore
  }

  func loadConnectionIds(session: ProductAccountSessionSnapshot) async throws
    -> [MailboxConnectionId]
  {
    let productAccountId = session.productAccountId
    var connectionIds = Set(
      try bestEffortConnectionIds {
        Array(try exchangeWebServicesStore.connectionIds(productAccountId: productAccountId))
      }
    )
    connectionIds.formUnion(
      try bestEffortConnectionIds {
        Array(
          try genericMailStore.connectionIds(
            productAccountId: ProductAccountId(productAccountId)
          )
        )
      }
    )
    connectionIds.formUnion(
      try bestEffortConnectionIds {
        try gmailStore.loadAll(productAccountId: productAccountId).keys.map {
          MailboxConnectionId(
            providerMailboxIdentity: StableProviderMailboxIdentity(
              providerId: .gmail,
              value: $0
            )
          )
        }
      }
    )
    connectionIds.formUnion(
      try bestEffortConnectionIds {
        try microsoftGraphStore.providerAccountIdentifiers(productAccountId: productAccountId).map {
          MailboxConnectionId(
            providerMailboxIdentity: StableProviderMailboxIdentity(
              providerId: .microsoftGraph,
              value: $0
            )
          )
        }
      }
    )
    return connectionIds.sorted { $0.rawValue < $1.rawValue }
  }

  private func bestEffortConnectionIds(
    _ load: () throws -> [MailboxConnectionId]
  ) throws -> [MailboxConnectionId] {
    do {
      return try load()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return []
    }
  }
}

struct KeychainProductSyncCacheClearer: ProductSyncCacheClearing {
  func clear(productAccountId: String) throws {
    var firstError: Error?
    let clearOperations: [() throws -> Void] = [
      { try KeychainMailboxConnectionSyncCacheStore().clear(productAccountId: productAccountId) },
      { try KeychainMailboxCleanupReceiptStore().clear(productAccountId: productAccountId) },
      { try KeychainNotificationRuleCacheStore().clear(productAccountId: productAccountId) },
      { try KeychainBackgroundContextCacheStore().clear(productAccountId: productAccountId) },
    ]
    for clear in clearOperations {
      do {
        try clear()
      } catch {
        firstError = firstError ?? error
      }
    }
    if let firstError { throw firstError }
  }
}

extension ProductSyncRecoveryKey {
  fileprivate init(pastedRawValue: String) throws {
    try self.init(rawValue: pastedRawValue.trimmingCharacters(in: .whitespacesAndNewlines))
  }
}

enum ProductAccountSessionState: Equatable {
  case loading
  case signedOut
  case signedIn(ProductAccountSessionSnapshot)
  case failed(String)
}

enum ProductAccountSessionError: LocalizedError, Equatable {
  case differentAppleAccount
  case pendingOutboxCleanup
  case recoveryNotBackedUp
  case recoveryKeyUnacknowledged
  case recoveryNotPending

  var errorDescription: String? {
    switch self {
    case .differentAppleAccount:
      return "Recent authentication must use the current Product Account."
    case .pendingOutboxCleanup:
      return "Finish cleaning up the previous Product Account before switching accounts."
    case .recoveryNotBackedUp:
      return "Back up the Recovery Key before signing out on this device."
    case .recoveryKeyUnacknowledged:
      return "Back up the current Recovery Key before replacing it."
    case .recoveryNotPending:
      return "Sign in with Apple before restoring Product Sync with a Recovery Key."
    }
  }
}

@MainActor
@Observable
// swiftlint:disable:next type_body_length
final class ProductAccountSession {
  private struct PendingProductSyncRecovery {
    let id = UUID()
    let credential: AppleSignInCredential
    let response: ProductAccountConnectResponse
  }

  private(set) var state: ProductAccountSessionState = .loading
  private(set) var deletionErrorMessage: String?
  private(set) var isDeletingProductAccount = false
  private(set) var signOutErrorMessage: String?
  private(set) var requiresProductSyncRecovery = false
  private(set) var unacknowledgedRecoveryKey: String?

  @ObservationIgnored private var bootstrapTask: Task<Void, Never>?
  @ObservationIgnored private var deletionTask: Task<Void, Never>?
  @ObservationIgnored private var mailboxFreshnessSession: ProductAccountSessionSnapshot?
  @ObservationIgnored private var mailboxFreshnessViewModel: MailboxFreshnessViewModel?
  @ObservationIgnored private var mailActionSession: ProductAccountSessionSnapshot?
  @ObservationIgnored private var mailActionViewModel: GmailMailActionViewModel?
  @ObservationIgnored private var pendingProductSyncRecovery: PendingProductSyncRecovery?
  @ObservationIgnored private var signOutTask: Task<Void, Never>?
  @ObservationIgnored private var signOutSnapshot: ProductAccountSessionSnapshot?
  @ObservationIgnored private var unacknowledgedRecoveryAccountId: String?
  @ObservationIgnored private var unacknowledgedRecoveryKeyMarker: UnacknowledgedRecoveryKey?
  private var isSigningOut = false
  private let appleSignInService: AppleSignInPerforming
  private let devicePushUnregistrationService: DevicePushUnregistering
  private let genericNotificationFallbackStore: GenericNotificationFallbackClearing
  private let gmailPushWakeupDrainer: GmailPushWakeupDraining
  private let notificationClearer: UserNotificationClearing
  private let productAccountService: ProductAccountConnecting
  private let sessionStore: ProductAccountSessionPersisting
  private let mailboxConnectionService: MailboxConnectionClearing
  private let mailboxConnectionIdLoader: MailboxConnectionIdLoading
  private let messageContentPreferences: MessageContentPreferences
  private let outboxDeliveryService: OutboxDeliveryClearing
  private let productSyncCacheClearer: ProductSyncCacheClearing
  private let productSyncKeyMaterialStore: ProductSyncKeyMaterialPersisting

  init(
    appleSignInService: AppleSignInPerforming,
    devicePushUnregistrationService: DevicePushUnregistering =
      DevicePushUnregistrationService(),
    genericNotificationFallbackStore: GenericNotificationFallbackClearing =
      UserDefaultsFallbackStore(),
    gmailPushWakeupDrainer: GmailPushWakeupDraining = GmailPushWakeupCoordinator.shared,
    notificationClearer: UserNotificationClearing = UserNotificationService(),
    productAccountService: ProductAccountConnecting = ConvexProductAccountService(),
    sessionStore: ProductAccountSessionPersisting = KeychainProductAccountSessionStore(),
    mailboxConnectionService: MailboxConnectionClearing = ProductAccountMailboxConnectionClearer(),
    mailboxConnectionIdLoader: MailboxConnectionIdLoading =
      ProductAccountMailboxConnectionIdLoader(),
    messageContentPreferences: MessageContentPreferences? = nil,
    outboxDeliveryService: OutboxDeliveryClearing = OutboxDeliveryService.shared,
    productSyncCacheClearer: ProductSyncCacheClearing = KeychainProductSyncCacheClearer(),
    productSyncKeyMaterialStore: ProductSyncKeyMaterialPersisting =
      KeychainProductSyncKeyMaterialStore()
  ) {
    self.appleSignInService = appleSignInService
    self.devicePushUnregistrationService = devicePushUnregistrationService
    self.genericNotificationFallbackStore = genericNotificationFallbackStore
    self.gmailPushWakeupDrainer = gmailPushWakeupDrainer
    self.notificationClearer = notificationClearer
    self.productAccountService = productAccountService
    self.sessionStore = sessionStore
    self.mailboxConnectionService = mailboxConnectionService
    self.mailboxConnectionIdLoader = mailboxConnectionIdLoader
    self.messageContentPreferences = messageContentPreferences ?? MessageContentPreferences()
    self.outboxDeliveryService = outboxDeliveryService
    self.productSyncCacheClearer = productSyncCacheClearer
    self.productSyncKeyMaterialStore = productSyncKeyMaterialStore
  }

  func bootstrap() async {
    if let bootstrapTask {
      await bootstrapTask.value
      return
    }
    state = .loading
    let task = Task { await performBootstrap() }
    bootstrapTask = task
    await task.value
  }

  func revalidateTrustedDeviceAfterForegrounding() async -> Bool {
    guard let snapshot = currentSignedInSnapshot(), !isSigningOut else { return false }
    return await withProductAccountOperation(productAccountId: snapshot.productAccountId) {
      guard isCurrent(snapshot) else { return false }
      do {
        let credential = try await foregroundRevalidationCredential(snapshot)
        guard credential.appleUserIdentifier == snapshot.appleUserIdentifier else {
          throw ProductAccountSessionError.differentAppleAccount
        }
        let response = try await productAccountService.connect(
          identityToken: credential.identityToken
        )
        guard response.productAccountId == snapshot.productAccountId else {
          throw ProductAccountSessionError.differentAppleAccount
        }
        _ = try await productAccountService.reconcileProductSyncKeyRotation(
          identityToken: credential.identityToken,
          productAccountId: response.productAccountId,
          trustedDeviceId: response.trustedDeviceId
        )
        let refreshedSnapshot = ProductAccountSessionSnapshot(
          appleUserIdentifier: credential.appleUserIdentifier,
          identityToken: credential.identityToken,
          identityTokenExpiresAt: AppleIdentityToken.expirationDate(
            from: credential.identityToken
          ),
          productAccountId: response.productAccountId,
          trustedDeviceId: response.trustedDeviceId
        )
        guard isCurrent(snapshot) else { return false }
        try sessionStore.save(refreshedSnapshot)
        state = .signedIn(refreshedSnapshot)
        return isCurrentSessionIdentity(refreshedSnapshot)
      } catch ProductAccountServiceError.trustedDeviceRevoked {
        await handleTrustedDeviceRevocation(snapshot)
        return false
      } catch ProductAccountServiceError.productAccountDeleted {
        await handleDeletedProductAccount(snapshot)
        return false
      } catch {
        // A transient foreground connectivity failure must not destroy an otherwise valid session.
        return false
      }
    }
  }

  private func foregroundRevalidationCredential(
    _ snapshot: ProductAccountSessionSnapshot
  ) async throws -> AppleSignInCredential {
    switch snapshot.identityTokenState() {
    case .active:
      try await appleSignInService.restoreSession(snapshot: snapshot)
    case .expired, .unverifiable:
      try await appleSignInService.signIn()
    }
  }

  // swiftlint:disable:next function_body_length
  func signInWithApple() async {
    let existingSnapshot = currentSignedInSnapshot() ?? (try? sessionStore.load())
    var attemptedCredential: AppleSignInCredential?
    let coordinatedProductAccountId =
      existingSnapshot?.productAccountId
      ?? pendingProductSyncRecovery?.response.productAccountId
    await withProductAccountOperation(productAccountId: coordinatedProductAccountId) {
      state = .loading
      clearPendingProductSyncRecovery()

      do {
        try await resumePendingSignOut()
        try await resumePendingOutboxCleanup()
        let credential = try await appleSignInService.signIn()
        attemptedCredential = credential
        await resumePendingTrustedDeviceUnregistrations(using: credential)
        let response = try await productAccountService.connect(
          identityToken: credential.identityToken
        )
        try requireAccountSwitchNotBlocked(
          from: try? sessionStore.load(),
          toProductAccountId: response.productAccountId
        )
        guard
          try await prepareProductSyncMaterial(
            credential: credential,
            response: response,
            allowCreation: shouldCreateProductSyncMaterialAfterSignIn(response: response)
          )
        else { return }
        try await completeSignIn(credential: credential, response: response)
      } catch ProductAccountServiceError.trustedDeviceRevoked {
        guard let existingSnapshot else {
          state = .signedOut
          return
        }
        guard
          attemptedCredential?.appleUserIdentifier == existingSnapshot.appleUserIdentifier
        else {
          state = .failed(ProductAccountSessionError.differentAppleAccount.localizedDescription)
          return
        }
        do {
          let mailboxCleanupError = try await clearRevokedSession(
            existingSnapshot,
            persistUnregistrationRetry: false
          )
          clearUnacknowledgedRecoveryKeyInMemory(
            productAccountId: existingSnapshot.productAccountId
          )
          state = mailboxCleanupError.map { .failed($0.localizedDescription) } ?? .signedOut
        } catch {
          state = .failed(error.localizedDescription)
        }
      } catch {
        state = .failed(error.localizedDescription)
      }
    }
  }

  func deleteProductAccount() async {
    if let deletionTask {
      await deletionTask.value
      return
    }
    guard let snapshot = currentSignedInSnapshot(), !isSigningOut else { return }
    let task = Task { await performProductAccountDeletion(snapshot: snapshot) }
    deletionTask = task
    await task.value
    deletionTask = nil
  }

  private func performProductAccountDeletion(
    snapshot: ProductAccountSessionSnapshot
  ) async {
    var rollbackError: Error?
    await withProductAccountOperation(productAccountId: snapshot.productAccountId) {
      guard isCurrent(snapshot) else { return }
      deletionErrorMessage = nil
      isDeletingProductAccount = true
      defer { isDeletingProductAccount = false }
      do {
        let credential = try await appleSignInService.signIn()
        guard credential.appleUserIdentifier == snapshot.appleUserIdentifier else {
          throw ProductAccountSessionError.differentAppleAccount
        }
        guard let authorizationCode = credential.authorizationCode else {
          throw AppleSignInError.missingAuthorizationCode
        }
        guard isCurrent(snapshot) else { throw CancellationError() }
        mailActionViewModel?.beginPreparingForSignOut()
        await outboxDeliveryService.suspend(productAccountId: snapshot.productAccountId)
        do {
          _ = try await productAccountService.deleteProductAccount(
            authorizationCode: authorizationCode,
            identityToken: credential.identityToken,
            trustedDeviceId: snapshot.trustedDeviceId
          )
          guard isCurrent(snapshot) else { throw CancellationError() }
          state = .loading
          do {
            try await clearDeletedProductAccountSession(snapshot)
            state = .signedOut
          } catch {
            state = .failed(error.localizedDescription)
            throw error
          }
        } catch {
          rollbackError = try await recoverFromProductAccountDeletionFailure(
            snapshot: snapshot,
            identityToken: credential.identityToken,
            deletionError: error
          )
        }
      } catch is CancellationError {
      } catch {
        deletionErrorMessage = error.localizedDescription
      }
    }
    if let rollbackError {
      await resumeProductAccountDeletionRollback(snapshot: snapshot)
      deletionErrorMessage = rollbackError.localizedDescription
    }
  }

  private func resumeProductAccountDeletionRollback(
    snapshot: ProductAccountSessionSnapshot
  ) async {
    guard isCurrent(snapshot) else { return }
    await mailActionViewModel?.resumeAfterSignOutRollback()
  }

  private func recoverFromProductAccountDeletionFailure(
    snapshot: ProductAccountSessionSnapshot,
    identityToken: String,
    deletionError: Error
  ) async throws -> Error? {
    var revalidationError: Error?
    do {
      let response = try await productAccountService.connect(identityToken: identityToken)
      guard response.productAccountId == snapshot.productAccountId else {
        throw ProductAccountSessionError.differentAppleAccount
      }
    } catch ProductAccountServiceError.productAccountDeleted {
      state = .loading
      do {
        try await clearDeletedProductAccountSession(snapshot)
        state = .signedOut
      } catch {
        state = .failed(error.localizedDescription)
        throw error
      }
      return nil
    } catch {
      revalidationError = error
    }
    if let revalidationError = revalidationError as? ProductAccountSessionError {
      return revalidationError
    }
    return deletionError
  }

  func revalidateProductAccountAfterForegrounding() async {
    guard let snapshot = currentSignedInSnapshot(), !isSigningOut,
      !isDeletingProductAccount
    else { return }
    await withProductAccountOperation(productAccountId: snapshot.productAccountId) {
      guard isCurrent(snapshot) else { return }
      do {
        let credential = try await appleSignInService.restoreSession(snapshot: snapshot)
        guard credential.appleUserIdentifier == snapshot.appleUserIdentifier else { return }
        let response = try await productAccountService.connect(
          identityToken: credential.identityToken
        )
        guard response.productAccountId == snapshot.productAccountId else { return }
        let refreshedSnapshot = ProductAccountSessionSnapshot(
          appleUserIdentifier: credential.appleUserIdentifier,
          identityToken: credential.identityToken,
          identityTokenExpiresAt: AppleIdentityToken.expirationDate(
            from: credential.identityToken
          ),
          productAccountId: response.productAccountId,
          trustedDeviceId: response.trustedDeviceId
        )
        try await replaceSessionAfterBootstrap(snapshot, with: refreshedSnapshot)
        state = .signedIn(refreshedSnapshot)
      } catch ProductAccountServiceError.productAccountDeleted {
        await handleDeletedProductAccount(snapshot)
      } catch ProductAccountServiceError.trustedDeviceRevoked {
        await handleTrustedDeviceRevocation(snapshot)
      } catch AppleSignInError.notAuthorized {
        state = .loading
        do {
          let mailboxCleanupError = try await clearRevokedSession(snapshot)
          clearUnacknowledgedRecoveryKeyInMemory(productAccountId: snapshot.productAccountId)
          if let mailboxCleanupError {
            state = .failed(mailboxCleanupError.localizedDescription)
          } else {
            state = .signedOut
          }
        } catch {
          state = .failed(error.localizedDescription)
        }
      } catch {
        // Keep a valid local session when connectivity or Apple authorization is unavailable.
      }
    }
  }

  private func clearDeletedProductAccountSession(
    _ snapshot: ProductAccountSessionSnapshot
  ) async throws {
    try sessionStore.savePendingDeletedProductAccountId(snapshot.productAccountId)
    try sessionStore.savePendingSignOutProductAccountId(snapshot.productAccountId)
    await gmailPushWakeupDrainer.cancelAndDrain(productAccountId: snapshot.productAccountId)
    clearMailboxFreshnessViewModel(
      purgingPersistedStateFor: snapshot.productAccountId
    )
    await MailboxWorkCoordinator.shared.cancelBodyPrefetch(
      productAccountId: snapshot.productAccountId
    )
    await retireMailActionViewModelForSignOut()
    try await clearLocalProductAccountData(
      session: snapshot,
      gmailPushWakeupsAlreadyDrained: true,
      purgingPrivacyOverrides: true
    )
    try clearPendingTrustedDeviceUnregistrations(
      productAccountId: snapshot.productAccountId
    )
    try await resumePendingSignOut(
      resumingExternalCleanup: false,
      finishingPushDrain: true
    )
    clearPendingProductSyncRecovery()
    clearUnacknowledgedRecoveryKeyInMemory(productAccountId: snapshot.productAccountId)
  }

  private func handleDeletedProductAccount(_ snapshot: ProductAccountSessionSnapshot) async {
    state = .loading
    do {
      try await clearDeletedProductAccountSession(snapshot)
      state = .signedOut
    } catch {
      state = .failed(error.localizedDescription)
    }
  }

  func signOut(
    afterRecoveryCheck preparation: @escaping () async -> Void = {}
  ) async {
    if let signOutTask {
      await signOutTask.value
      return
    }
    let productAccountId =
      currentSignedInSnapshot()?.productAccountId
      ?? (try? sessionStore.load())?.productAccountId
      ?? pendingProductSyncRecovery?.response.productAccountId
    let task = Task {
      await performCoordinatedSignOut(
        productAccountId: productAccountId,
        afterRecoveryCheck: preparation
      )
    }
    signOutTask = task
    await task.value
    signOutTask = nil
  }

  // swiftlint:disable:next function_body_length
  private func performSignOut(
    afterRecoveryCheck preparation: () async -> Void
  ) async {
    var preparedDestructiveCleanup = false
    defer {
      isSigningOut = false
      signOutSnapshot = nil
    }
    let snapshot = signOutSnapshot ?? (try? sessionStore.load())
    await suspendOutboxDelivery(for: snapshot)
    do {
      let cleanupSnapshot = try await prepareForSignOut(
        snapshot,
        preparation: {
          await preparation()
          preparedDestructiveCleanup = true
        }
      )
      if let cleanupSnapshot {
        // Trusted Device unregistration below removes backend routing even if
        // this best-effort provider-specific push cleanup fails.
        try? await devicePushUnregistrationService.unregister(session: cleanupSnapshot)
        guard !signOutSnapshotWasReplaced(snapshot) else { return }
      }
      var mailboxCleanupError: Error?
      if let cleanupSnapshot {
        do {
          try await mailboxConnectionService.clearLocalConnection(
            session: cleanupSnapshot,
            isStillCurrent: {
              !self.signOutSnapshotWasReplaced(snapshot)
            }
          )
        } catch {
          mailboxCleanupError = error
        }
      }
      if let mailboxCleanupError {
        state = .failed(mailboxCleanupError.localizedDescription)
        return
      }
      guard !signOutSnapshotWasReplaced(snapshot) else { return }
      if let snapshot, let cleanupSnapshot {
        try await unregisterTrustedDeviceOrPersistForRetry(cleanupSnapshot)
        guard !signOutSnapshotWasReplaced(snapshot) else { return }
        try await resumePendingSignOut(resumingExternalCleanup: false)
      } else {
        try sessionStore.clear()
      }
      guard
        currentSignedInSnapshot() == nil || currentSignedInSnapshot() == snapshot,
        (try? sessionStore.load()) == nil
      else { return }
      state = .signedOut
    } catch {
      await publishSignOutFailure(
        error,
        snapshot: snapshot,
        preparedDestructiveCleanup: preparedDestructiveCleanup
      )
    }
  }

  private func suspendOutboxDelivery(
    for snapshot: ProductAccountSessionSnapshot?
  ) async {
    guard let snapshot else { return }
    await outboxDeliveryService.suspend(productAccountId: snapshot.productAccountId)
  }

  private func unregisterTrustedDeviceForSignOut(
    _ snapshot: ProductAccountSessionSnapshot
  ) async throws {
    _ = try await productAccountService.unregisterTrustedDevice(
      identityToken: snapshot.identityToken,
      trustedDeviceId: snapshot.trustedDeviceId
    )
  }

  private func unregisterTrustedDeviceOrPersistForRetry(
    _ snapshot: ProductAccountSessionSnapshot
  ) async throws {
    do {
      try await unregisterTrustedDeviceForSignOut(snapshot)
    } catch ProductAccountServiceError.productAccountDeleted {
      try sessionStore.clearPendingTrustedDeviceUnregistration(
        trustedDeviceId: snapshot.trustedDeviceId
      )
    } catch {
      try persistTrustedDeviceUnregistrationRetry(snapshot)
    }
  }

  private func persistTrustedDeviceUnregistrationRetry(
    _ snapshot: ProductAccountSessionSnapshot
  ) throws {
    try sessionStore.savePendingTrustedDeviceUnregistration(
      PendingTrustedDeviceUnregistration(
        appleUserIdentifier: snapshot.appleUserIdentifier,
        productAccountId: snapshot.productAccountId,
        trustedDeviceId: snapshot.trustedDeviceId
      )
    )
  }

  private func shouldCreateProductSyncMaterialAfterSignIn(
    response: ProductAccountConnectResponse
  ) -> Bool {
    response.accountCreated
      || (!response.productSyncMaterialInitialized && !response.deviceRegistered)
  }

  private func replaceSessionAfterBootstrap(
    _ existingSnapshot: ProductAccountSessionSnapshot,
    with snapshot: ProductAccountSessionSnapshot
  ) async throws {
    try trackOutboxCleanupIfProductAccountChanged(
      from: existingSnapshot,
      to: snapshot
    )
    do {
      try sessionStore.save(snapshot)
    } catch {
      try? sessionStore.clearPendingOutboxCleanupProductAccountId()
      throw error
    }
    do {
      try await clearOutboxIfProductAccountChanged(
        from: existingSnapshot,
        to: snapshot
      )
      try await clearLocalMailboxConnectionIfProductAccountChanged(
        from: existingSnapshot,
        to: snapshot
      )
    } catch {
      do {
        try sessionStore.save(existingSnapshot)
        try? sessionStore.clearPendingOutboxCleanupProductAccountId()
      } catch {
        // Keep the marker when rollback fails so bootstrap can clean the retired account.
      }
      throw error
    }
    await unregisterDeviceIfProductAccountChanged(
      from: existingSnapshot,
      to: snapshot
    )
  }

  private func unregisterDeviceIfProductAccountChanged(
    from existingSnapshot: ProductAccountSessionSnapshot?,
    to snapshot: ProductAccountSessionSnapshot
  ) async {
    guard
      let existingSnapshot,
      existingSnapshot.productAccountId != snapshot.productAccountId
    else {
      return
    }

    try? await devicePushUnregistrationService.unregister(session: existingSnapshot)
  }

  private func currentSignedInSnapshot() -> ProductAccountSessionSnapshot? {
    guard case .signedIn(let snapshot) = state else {
      return nil
    }

    return snapshot
  }
}

extension ProductAccountSession {
  fileprivate func trackOutboxCleanupIfProductAccountChanged(
    from existingSnapshot: ProductAccountSessionSnapshot?,
    to snapshot: ProductAccountSessionSnapshot
  ) throws {
    guard
      let existingSnapshot,
      existingSnapshot.productAccountId != snapshot.productAccountId
    else {
      return
    }

    try requireAccountSwitchNotBlocked(
      from: existingSnapshot,
      toProductAccountId: snapshot.productAccountId
    )

    try sessionStore.savePendingOutboxCleanupProductAccountId(
      existingSnapshot.productAccountId
    )
  }

  fileprivate func requireAccountSwitchNotBlocked(
    from existingSnapshot: ProductAccountSessionSnapshot?,
    toProductAccountId: String
  ) throws {
    guard
      let existingSnapshot,
      existingSnapshot.productAccountId != toProductAccountId,
      let pendingProductAccountId = try sessionStore.loadPendingOutboxCleanupProductAccountId(),
      pendingProductAccountId != existingSnapshot.productAccountId
    else {
      return
    }

    throw ProductAccountSessionError.pendingOutboxCleanup
  }

  fileprivate func clearLocalMailboxConnectionIfProductAccountChanged(
    from existingSnapshot: ProductAccountSessionSnapshot?,
    to snapshot: ProductAccountSessionSnapshot
  ) async throws {
    guard
      let existingSnapshot,
      existingSnapshot.productAccountId != snapshot.productAccountId
    else {
      return
    }

    await outboxDeliveryService.suspend(productAccountId: existingSnapshot.productAccountId)
    try await mailboxConnectionService.clearLocalConnection(session: existingSnapshot)
  }

  fileprivate func clearOutboxIfProductAccountChanged(
    from existingSnapshot: ProductAccountSessionSnapshot?,
    to snapshot: ProductAccountSessionSnapshot
  ) async throws {
    guard
      let existingSnapshot,
      existingSnapshot.productAccountId != snapshot.productAccountId
    else {
      return
    }

    try await outboxDeliveryService.clear(session: existingSnapshot)
    try? sessionStore.clearPendingOutboxCleanupProductAccountId()
  }

  fileprivate func clearLocalProductAccountData(
    session: ProductAccountSessionSnapshot,
    gmailPushWakeupsAlreadyDrained: Bool = false,
    purgingPrivacyOverrides: Bool = false,
    isStillCurrent: @escaping @MainActor () -> Bool = { true }
  ) async throws {
    try await outboxDeliveryService.clear(session: session)
    if !gmailPushWakeupsAlreadyDrained {
      await gmailPushWakeupDrainer.cancelAndDrain(productAccountId: session.productAccountId)
    }
    if purgingPrivacyOverrides {
      do {
        let connectionIds = try await mailboxConnectionIdLoader.loadConnectionIds(session: session)
        messageContentPreferences.clearRemoteContentOverrides(for: connectionIds)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // Privacy cleanup is best-effort and must not block account-local teardown.
      }
    }
    try await mailboxConnectionService.clearLocalConnection(
      session: session,
      isStillCurrent: isStillCurrent
    )
    notificationClearer.clear(productAccountId: session.productAccountId)
  }
}

extension ProductAccountSession {
  // swiftlint:disable:next function_body_length
  func restoreProductSyncMaterial(recoveryKey rawValue: String) async {
    guard let pendingProductSyncRecovery else {
      state = .failed(ProductAccountSessionError.recoveryNotPending.localizedDescription)
      return
    }
    let productAccountId = pendingProductSyncRecovery.response.productAccountId
    await withProductAccountOperation(productAccountId: productAccountId) {
      guard
        self.pendingProductSyncRecovery?.id == pendingProductSyncRecovery.id,
        !isSigningOut
      else { return }
      state = .loading

      do {
        let credential = try await appleSignInService.signIn()
        guard
          credential.appleUserIdentifier
            == pendingProductSyncRecovery.credential.appleUserIdentifier
        else {
          throw ProductAccountSessionError.differentAppleAccount
        }
        guard
          self.pendingProductSyncRecovery?.id == pendingProductSyncRecovery.id,
          !isSigningOut
        else { throw CancellationError() }
        guard
          let currentRecoveryMaterial =
            try await productAccountService.productSyncRecoveryMaterial(
              identityToken: credential.identityToken,
              trustedDeviceId: pendingProductSyncRecovery.response.trustedDeviceId
            )
        else {
          throw ProductSyncKeyMaterialStoreError.recoveryRequired
        }
        guard
          self.pendingProductSyncRecovery?.id == pendingProductSyncRecovery.id,
          !isSigningOut
        else { throw CancellationError() }
        _ = try productSyncKeyMaterialStore.restore(
          productAccountId: productAccountId,
          recoveryKey: ProductSyncRecoveryKey(pastedRawValue: rawValue),
          recoveryWrappedAccountKey: currentRecoveryMaterial.encryptedPayload
        )
        try await completeSignIn(
          credential: credential,
          response: pendingProductSyncRecovery.response
        )
        clearPendingProductSyncRecovery()
      } catch ProductAccountServiceError.trustedDeviceRevoked {
        let response = pendingProductSyncRecovery.response
        let credential = pendingProductSyncRecovery.credential
        let snapshot = ProductAccountSessionSnapshot(
          appleUserIdentifier: credential.appleUserIdentifier,
          identityToken: credential.identityToken,
          identityTokenExpiresAt: AppleIdentityToken.expirationDate(
            from: credential.identityToken
          ),
          productAccountId: response.productAccountId,
          trustedDeviceId: response.trustedDeviceId
        )
        do {
          let mailboxCleanupError = try await clearRevokedSession(
            snapshot,
            persistUnregistrationRetry: false
          )
          clearUnacknowledgedRecoveryKeyInMemory(productAccountId: productAccountId)
          clearPendingProductSyncRecovery()
          state = mailboxCleanupError.map { .failed($0.localizedDescription) } ?? .signedOut
        } catch {
          state = .failed(error.localizedDescription)
        }
      } catch is CancellationError {
      } catch {
        state = .failed(error.localizedDescription)
      }
    }
  }

  private func withProductAccountOperation<Result>(
    productAccountId: String?,
    operation: () async -> Result
  ) async -> Result {
    if let productAccountId {
      await productAccountRecoveryOperationGate.acquire(
        productAccountId: productAccountId
      )
    }
    let result = await operation()
    if let productAccountId {
      await productAccountRecoveryOperationGate.release(
        productAccountId: productAccountId
      )
    }
    return result
  }

  func isCurrent(_ snapshot: ProductAccountSessionSnapshot) -> Bool {
    !isSigningOut && currentSignedInSnapshot() == snapshot
  }

  func isCurrentSessionIdentity(_ snapshot: ProductAccountSessionSnapshot) -> Bool {
    guard !isSigningOut, let currentSnapshot = currentSignedInSnapshot() else {
      return false
    }
    return currentSnapshot.appleUserIdentifier == snapshot.appleUserIdentifier
      && currentSnapshot.productAccountId == snapshot.productAccountId
      && currentSnapshot.trustedDeviceId == snapshot.trustedDeviceId
  }

  private func signOutSnapshotWasReplaced(
    _ snapshot: ProductAccountSessionSnapshot?
  ) -> Bool {
    if let currentSnapshot = currentSignedInSnapshot() {
      return currentSnapshot != snapshot
    }
    if let storedSnapshot = try? sessionStore.load() {
      return storedSnapshot != snapshot
    }
    return false
  }

  private func publishSignOutFailure(
    _ error: Error,
    snapshot: ProductAccountSessionSnapshot?,
    preparedDestructiveCleanup: Bool
  ) async {
    if !preparedDestructiveCleanup, let snapshot,
      !signOutSnapshotWasReplaced(snapshot)
    {
      await mailActionViewModel?.resumeAfterSignOutRollback()
      signOutErrorMessage = error.localizedDescription
      state = .signedIn(snapshot)
    } else {
      state = .failed(error.localizedDescription)
    }
  }

  private func prepareForSignOut(
    _ snapshot: ProductAccountSessionSnapshot?,
    preparation: () async -> Void
  ) async throws -> ProductAccountSessionSnapshot? {
    guard let snapshot else {
      await preparation()
      return nil
    }
    let identityToken = try await verifyProductSyncRecoveryIsBackedUp(snapshot)
    try sessionStore.savePendingSignOutProductAccountId(snapshot.productAccountId)
    do {
      try await outboxDeliveryService.clear(session: snapshot)
    } catch {
      try? sessionStore.clearPendingSignOutProductAccountId()
      throw error
    }
    await retireMailActionViewModelForSignOut()
    await preparation()
    return ProductAccountSessionSnapshot(
      appleUserIdentifier: snapshot.appleUserIdentifier,
      identityToken: identityToken,
      identityTokenExpiresAt: AppleIdentityToken.expirationDate(from: identityToken),
      productAccountId: snapshot.productAccountId,
      trustedDeviceId: snapshot.trustedDeviceId
    )
  }

  private func performCoordinatedSignOut(
    productAccountId: String?,
    afterRecoveryCheck preparation: () async -> Void
  ) async {
    if let productAccountId {
      await productAccountRecoveryOperationGate.acquire(
        productAccountId: productAccountId
      )
    }
    beginSignOut()
    await performSignOut(afterRecoveryCheck: preparation)
    if let productAccountId {
      await productAccountRecoveryOperationGate.release(
        productAccountId: productAccountId
      )
    }
  }

  private func verifyProductSyncRecoveryIsBackedUp(
    _ snapshot: ProductAccountSessionSnapshot
  ) async throws -> String {
    let recoveryKeyMarker = try sessionStore.loadUnacknowledgedRecoveryKey(
      productAccountId: snapshot.productAccountId
    )
    if recoveryKeyMarker == nil {
      clearUnacknowledgedRecoveryKeyInMemory(productAccountId: snapshot.productAccountId)
    }
    let material = try productSyncKeyMaterialStore.load(
      productAccountId: snapshot.productAccountId
    )
    if let recoveryKeyMarker {
      if recoveryKeyMarker.recoveryWrappedAccountKey == nil
        || recoveryKeyMarker.recoveryWrappedAccountKey == material?.recoveryWrappedAccountKey
      {
        unacknowledgedRecoveryKey = recoveryKeyMarker.recoveryKey
        unacknowledgedRecoveryKeyMarker = recoveryKeyMarker
        unacknowledgedRecoveryAccountId = snapshot.productAccountId
        throw ProductAccountSessionError.recoveryNotBackedUp
      }
      try? sessionStore.clearUnacknowledgedRecoveryKey(
        productAccountId: snapshot.productAccountId
      )
      clearUnacknowledgedRecoveryKeyInMemory(productAccountId: snapshot.productAccountId)
    }
    let identityToken = try await identityTokenForRecoveryCheck(snapshot)
    guard
      try await productAccountService.productSyncRecoveryIsBackedUp(
        identityToken: identityToken,
        trustedDeviceId: snapshot.trustedDeviceId,
        expectedRecoveryWrappedAccountKey: material?.recoveryWrappedAccountKey
      )
    else {
      throw ProductAccountSessionError.recoveryNotBackedUp
    }
    return identityToken
  }

  private func identityTokenForRecoveryCheck(
    _ snapshot: ProductAccountSessionSnapshot
  ) async throws -> String {
    let minimumExpiration = Date().addingTimeInterval(
      signOutTokenValidityMargin
    )
    guard snapshot.identityTokenState(at: minimumExpiration) != .active else {
      return snapshot.identityToken
    }
    let credential = try await appleSignInService.signIn()
    guard credential.appleUserIdentifier == snapshot.appleUserIdentifier else {
      throw ProductAccountSessionError.differentAppleAccount
    }
    guard !signOutSnapshotWasReplaced(snapshot) else { throw CancellationError() }
    return credential.identityToken
  }

  private func prepareProductSyncMaterial(
    credential: AppleSignInCredential,
    response: ProductAccountConnectResponse,
    allowCreation: Bool
  ) async throws -> Bool {
    do {
      _ = try productSyncKeyMaterialStore.ensureMaterial(
        productAccountId: response.productAccountId,
        allowCreation: allowCreation
      )
      return true
    } catch ProductSyncKeyMaterialStoreError.recoveryRequired {
      guard
        try await productAccountService.productSyncRecoveryMaterial(
          identityToken: credential.identityToken,
          trustedDeviceId: response.trustedDeviceId
        ) != nil
      else {
        throw ProductSyncKeyMaterialStoreError.recoveryRequired
      }
      pendingProductSyncRecovery = PendingProductSyncRecovery(
        credential: credential,
        response: response
      )
      requiresProductSyncRecovery = true
      state = .failed(ProductSyncKeyMaterialStoreError.recoveryRequired.localizedDescription)
      return false
    }
  }

  // swiftlint:disable:next function_body_length
  private func completeSignIn(
    credential: AppleSignInCredential,
    response: ProductAccountConnectResponse
  ) async throws {
    _ = try await productAccountService.reconcileProductSyncKeyRotation(
      identityToken: credential.identityToken,
      productAccountId: response.productAccountId,
      trustedDeviceId: response.trustedDeviceId
    )
    _ = try await productAccountService.markProductSyncMaterialInitialized(
      identityToken: credential.identityToken,
      trustedDeviceId: response.trustedDeviceId
    )
    let snapshot = ProductAccountSessionSnapshot(
      appleUserIdentifier: credential.appleUserIdentifier,
      identityToken: credential.identityToken,
      identityTokenExpiresAt: AppleIdentityToken.expirationDate(
        from: credential.identityToken
      ),
      productAccountId: response.productAccountId,
      trustedDeviceId: response.trustedDeviceId
    )
    let previousSnapshot = try? sessionStore.load()
    try trackOutboxCleanupIfProductAccountChanged(
      from: previousSnapshot,
      to: snapshot
    )
    do {
      try sessionStore.save(snapshot)
    } catch {
      try? sessionStore.clearPendingOutboxCleanupProductAccountId()
      throw error
    }
    do {
      try await clearOutboxIfProductAccountChanged(
        from: previousSnapshot,
        to: snapshot
      )
      try await clearLocalMailboxConnectionIfProductAccountChanged(
        from: previousSnapshot,
        to: snapshot
      )
    } catch {
      if let previousSnapshot {
        do {
          try sessionStore.save(previousSnapshot)
          try? sessionStore.clearPendingOutboxCleanupProductAccountId()
        } catch {
          // Keep the marker when rollback fails so bootstrap can clean the retired account.
        }
      }
      throw error
    }
    await unregisterDeviceIfProductAccountChanged(
      from: previousSnapshot,
      to: snapshot
    )
    loadUnacknowledgedRecoveryKey(productAccountId: snapshot.productAccountId)
    state = .signedIn(snapshot)
  }

  private func clearPendingProductSyncRecovery() {
    pendingProductSyncRecovery = nil
    requiresProductSyncRecovery = false
  }

  private func prepareProductSyncMaterialForBootstrap(
    credential: AppleSignInCredential,
    response: ProductAccountConnectResponse
  ) async throws -> Bool {
    try await prepareProductSyncMaterial(
      credential: credential,
      response: response,
      allowCreation: response.accountCreated
    )
  }
}

extension ProductAccountSession {
  // swiftlint:disable:next cyclomatic_complexity function_body_length
  private func performBootstrap() async {
    guard await prepareForBootstrap() else { return }
    guard let snapshot = try? sessionStore.load() else {
      state = .signedOut
      return
    }

    do {
      let credential = try await appleSignInService.restoreSession(snapshot: snapshot)
      let response = try await productAccountService.connect(
        identityToken: credential.identityToken
      )
      try requireAccountSwitchNotBlocked(
        from: snapshot,
        toProductAccountId: response.productAccountId
      )
      guard
        try await prepareProductSyncMaterialForBootstrap(
          credential: credential,
          response: response
        )
      else { return }
      _ = try await productAccountService.reconcileProductSyncKeyRotation(
        identityToken: credential.identityToken,
        productAccountId: response.productAccountId,
        trustedDeviceId: response.trustedDeviceId
      )
      _ = try await productAccountService.markProductSyncMaterialInitialized(
        identityToken: credential.identityToken,
        trustedDeviceId: response.trustedDeviceId
      )
      let refreshedSnapshot = ProductAccountSessionSnapshot(
        appleUserIdentifier: credential.appleUserIdentifier,
        identityToken: credential.identityToken,
        identityTokenExpiresAt: AppleIdentityToken.expirationDate(
          from: credential.identityToken
        ),
        productAccountId: response.productAccountId,
        trustedDeviceId: response.trustedDeviceId
      )
      try await replaceSessionAfterBootstrap(
        snapshot,
        with: refreshedSnapshot
      )
      loadUnacknowledgedRecoveryKey(productAccountId: refreshedSnapshot.productAccountId)
      state = .signedIn(refreshedSnapshot)
    } catch ProductAccountServiceError.trustedDeviceRevoked {
      do {
        let mailboxCleanupError = try await clearRevokedSession(
          snapshot,
          persistUnregistrationRetry: false
        )
        clearUnacknowledgedRecoveryKeyInMemory(productAccountId: snapshot.productAccountId)
        if let mailboxCleanupError {
          state = .failed(mailboxCleanupError.localizedDescription)
        } else {
          state = .signedOut
        }
      } catch {
        state = .failed(error.localizedDescription)
      }
    } catch ProductAccountServiceError.productAccountDeleted {
      do {
        try await clearDeletedProductAccountSession(snapshot)
        state = .signedOut
      } catch {
        state = .failed(error.localizedDescription)
      }
    } catch let error as AppleSignInError {
      switch error {
      case .notAuthorized:
        state = .loading
        do {
          let mailboxCleanupError = try await clearRevokedSession(snapshot)
          clearUnacknowledgedRecoveryKeyInMemory(productAccountId: snapshot.productAccountId)
          if let mailboxCleanupError {
            state = .failed(mailboxCleanupError.localizedDescription)
          } else {
            state = .signedOut
          }
        } catch {
          state = .failed(error.localizedDescription)
        }
      default:
        state = .failed(error.localizedDescription)
      }
    } catch {
      state = .failed(error.localizedDescription)
    }
  }

  private func prepareForBootstrap() async -> Bool {
    do {
      try await resumePendingSignOut()
      try await resumePendingOutboxCleanup()
      return true
    } catch {
      state = .failed(error.localizedDescription)
      return false
    }
  }

  private func clearRevokedSession(
    _ snapshot: ProductAccountSessionSnapshot,
    persistUnregistrationRetry: Bool = true
  ) async throws -> Error? {
    try sessionStore.savePendingSignOutProductAccountId(
      snapshot.productAccountId
    )
    await gmailPushWakeupDrainer.cancelAndDrain(productAccountId: snapshot.productAccountId)
    clearMailboxFreshnessViewModel(
      purgingPersistedStateFor: snapshot.productAccountId
    )
    await MailboxWorkCoordinator.shared.cancelBodyPrefetch(
      productAccountId: snapshot.productAccountId
    )
    await retireMailActionViewModelForSignOut()
    try await outboxDeliveryService.clear(session: snapshot)
    var mailboxCleanupError: Error?
    do {
      try await mailboxConnectionService.clearLocalConnection(session: snapshot)
    } catch {
      mailboxCleanupError = error
    }
    if let mailboxCleanupError {
      return mailboxCleanupError
    }
    notificationClearer.clear(productAccountId: snapshot.productAccountId)
    if persistUnregistrationRetry {
      try persistTrustedDeviceUnregistrationRetry(snapshot)
    }
    try await resumePendingSignOut(
      resumingExternalCleanup: false,
      finishingPushDrain: true
    )
    return mailboxCleanupError
  }

  func handleTrustedDeviceRevocation(_ snapshot: ProductAccountSessionSnapshot) async {
    guard isCurrentSessionIdentity(snapshot) else { return }
    do {
      let mailboxCleanupError = try await clearRevokedSession(
        snapshot,
        persistUnregistrationRetry: false
      )
      clearUnacknowledgedRecoveryKeyInMemory(productAccountId: snapshot.productAccountId)
      state = mailboxCleanupError.map { .failed($0.localizedDescription) } ?? .signedOut
    } catch {
      state = .failed(error.localizedDescription)
    }
  }

  // swiftlint:disable:next function_body_length
  private func resumePendingSignOut(
    resumingExternalCleanup: Bool = true,
    finishingPushDrain: Bool = true
  ) async throws {
    let deletedProductAccountId = try sessionStore.loadPendingDeletedProductAccountId()
    let pendingSignOutProductAccountId = try sessionStore.loadPendingSignOutProductAccountId()
    guard let productAccountId = pendingSignOutProductAccountId ?? deletedProductAccountId else {
      return
    }
    let backendAlreadyDeleted = deletedProductAccountId == productAccountId
    if backendAlreadyDeleted {
      if resumingExternalCleanup,
        let snapshot = try sessionStore.load(),
        snapshot.productAccountId == productAccountId
      {
        try await clearLocalProductAccountData(
          session: snapshot,
          purgingPrivacyOverrides: true
        )
      }
      clearMailboxFreshnessViewModel(purgingPersistedStateFor: productAccountId)
      try clearPendingTrustedDeviceUnregistrations(productAccountId: productAccountId)
    } else if resumingExternalCleanup,
      let snapshot = try sessionStore.load(),
      snapshot.productAccountId == productAccountId
    {
      if snapshot.identityTokenState() == .active {
        try? await devicePushUnregistrationService.unregister(session: snapshot)
      } else {
        try persistTrustedDeviceUnregistrationRetry(snapshot)
      }
      try await clearLocalProductAccountData(session: snapshot)
      clearMailboxFreshnessViewModel(purgingPersistedStateFor: productAccountId)
      if snapshot.identityTokenState() == .active {
        try await unregisterTrustedDeviceOrPersistForRetry(snapshot)
      }
    }
    try sessionStore.clear()
    try productSyncCacheClearer.clear(productAccountId: productAccountId)
    try productSyncKeyMaterialStore.clear(
      productAccountId: productAccountId
    )
    genericNotificationFallbackStore.clear(productAccountId: productAccountId)
    try sessionStore.clearUnacknowledgedRecoveryKey(
      productAccountId: productAccountId
    )
    if pendingSignOutProductAccountId == productAccountId {
      try sessionStore.clearPendingSignOutProductAccountId()
    }
    if deletedProductAccountId == productAccountId {
      try sessionStore.clearPendingDeletedProductAccountId()
    }
    if finishingPushDrain {
      gmailPushWakeupDrainer.finishDraining(productAccountId: productAccountId)
    }
  }

  private func resumePendingOutboxCleanup() async throws {
    guard let productAccountId = try sessionStore.loadPendingOutboxCleanupProductAccountId()
    else {
      return
    }
    if try sessionStore.load()?.productAccountId == productAccountId {
      try sessionStore.clearPendingOutboxCleanupProductAccountId()
      return
    }
    do {
      try await outboxDeliveryService.clear(productAccountId: productAccountId)
      try sessionStore.clearPendingOutboxCleanupProductAccountId()
    } catch {
      // Keep the marker so a later launch can retry retired-account cleanup.
    }
  }

  private func resumePendingTrustedDeviceUnregistrations(
    using credential: AppleSignInCredential
  ) async {
    guard let unregistrations = try? sessionStore.loadPendingTrustedDeviceUnregistrations() else {
      return
    }
    for unregistration in unregistrations
    where unregistration.appleUserIdentifier == credential.appleUserIdentifier {
      let cleanupSnapshot = ProductAccountSessionSnapshot(
        appleUserIdentifier: unregistration.appleUserIdentifier,
        identityToken: credential.identityToken,
        identityTokenExpiresAt: AppleIdentityToken.expirationDate(
          from: credential.identityToken
        ),
        productAccountId: unregistration.productAccountId,
        trustedDeviceId: unregistration.trustedDeviceId
      )
      do {
        try await unregisterTrustedDeviceForSignOut(cleanupSnapshot)
        try sessionStore.clearPendingTrustedDeviceUnregistration(
          trustedDeviceId: unregistration.trustedDeviceId
        )
      } catch {
        continue
      }
    }
  }

  private func clearPendingTrustedDeviceUnregistrations(
    productAccountId: String
  ) throws {
    for unregistration in try sessionStore.loadPendingTrustedDeviceUnregistrations()
    where unregistration.productAccountId == productAccountId {
      try sessionStore.clearPendingTrustedDeviceUnregistration(
        trustedDeviceId: unregistration.trustedDeviceId
      )
    }
  }

  func recentIdentityToken(
    for snapshot: ProductAccountSessionSnapshot
  ) async throws -> String {
    guard isCurrent(snapshot) else { throw CancellationError() }
    let credential = try await appleSignInService.signIn()
    guard credential.appleUserIdentifier == snapshot.appleUserIdentifier else {
      throw ProductAccountSessionError.differentAppleAccount
    }
    guard isCurrent(snapshot) else { throw CancellationError() }
    return credential.identityToken
  }

  func beginSignOut() {
    guard !isSigningOut else { return }
    signOutErrorMessage = nil
    signOutSnapshot = currentSignedInSnapshot()
    isSigningOut = true
    state = .loading
    clearPendingProductSyncRecovery()
    clearMailboxFreshnessViewModel()
    mailActionViewModel?.beginPreparingForSignOut()
  }

  func preserveUnacknowledgedRecoveryKey(_ recoveryKey: String) throws {
    guard
      let productAccountId =
        currentSignedInSnapshot()?.productAccountId
        ?? (try? sessionStore.load())?.productAccountId
    else {
      throw CancellationError()
    }
    let persistedMarker = try sessionStore.loadUnacknowledgedRecoveryKey(
      productAccountId: productAccountId
    )
    guard
      let material = try productSyncKeyMaterialStore.load(productAccountId: productAccountId)
    else {
      throw ProductSyncKeyMaterialStoreError.recoveryRequired
    }
    let hasUnacknowledgedCurrentKey =
      persistedMarker.map { marker in
        marker.recoveryKey != recoveryKey
          && (marker == unacknowledgedRecoveryKeyMarker
            || marker.recoveryWrappedAccountKey == nil
            || marker.recoveryWrappedAccountKey == material.recoveryWrappedAccountKey)
      } ?? false
    guard !hasUnacknowledgedCurrentKey else {
      throw ProductAccountSessionError.recoveryKeyUnacknowledged
    }
    let marker = UnacknowledgedRecoveryKey(
      recoveryKey: recoveryKey,
      recoveryWrappedAccountKey: material.recoveryWrappedAccountKey
    )
    try sessionStore.saveUnacknowledgedRecoveryKey(
      marker,
      productAccountId: productAccountId
    )
    unacknowledgedRecoveryKey = recoveryKey
    unacknowledgedRecoveryKeyMarker = marker
    unacknowledgedRecoveryAccountId = productAccountId
  }

  func acknowledgeRecoveryKey(
    _ recoveryKey: String,
    productAccountId: String
  ) throws {
    guard currentSignedInSnapshot()?.productAccountId == productAccountId else { return }
    let persistedRecoveryKey = try sessionStore.loadUnacknowledgedRecoveryKey(
      productAccountId: productAccountId
    )
    let currentWrapper = try productSyncKeyMaterialStore.load(
      productAccountId: productAccountId
    )?.recoveryWrappedAccountKey
    guard
      persistedRecoveryKey == nil
        || (persistedRecoveryKey?.recoveryKey == recoveryKey
          && (persistedRecoveryKey?.recoveryWrappedAccountKey == nil
            || persistedRecoveryKey?.recoveryWrappedAccountKey == currentWrapper))
    else { return }
    if persistedRecoveryKey?.recoveryKey == recoveryKey {
      try sessionStore.clearUnacknowledgedRecoveryKey(productAccountId: productAccountId)
    }
    clearUnacknowledgedRecoveryKeyInMemory(
      recoveryKey: recoveryKey,
      productAccountId: productAccountId
    )
  }

  func rejectUnacknowledgedRecoveryKey(
    _ recoveryKey: String,
    productAccountId: String
  ) throws {
    let persistedRecoveryKey = try sessionStore.loadUnacknowledgedRecoveryKey(
      productAccountId: productAccountId
    )
    guard persistedRecoveryKey?.recoveryKey == recoveryKey else { return }
    try sessionStore.clearUnacknowledgedRecoveryKey(productAccountId: productAccountId)
    clearUnacknowledgedRecoveryKeyInMemory(
      recoveryKey: recoveryKey,
      productAccountId: productAccountId
    )
  }

  private func loadUnacknowledgedRecoveryKey(productAccountId: String) {
    let marker = try? sessionStore.loadUnacknowledgedRecoveryKey(
      productAccountId: productAccountId
    )
    let currentWrapper = try? productSyncKeyMaterialStore.load(
      productAccountId: productAccountId
    )?.recoveryWrappedAccountKey
    guard let marker,
      marker.recoveryWrappedAccountKey == nil
        || marker.recoveryWrappedAccountKey == currentWrapper
    else {
      clearUnacknowledgedRecoveryKeyInMemory(productAccountId: productAccountId)
      return
    }
    unacknowledgedRecoveryKey = marker.recoveryKey
    unacknowledgedRecoveryKeyMarker = marker
    unacknowledgedRecoveryAccountId = productAccountId
  }

  func reloadUnacknowledgedRecoveryKey(productAccountId: String) {
    loadUnacknowledgedRecoveryKey(productAccountId: productAccountId)
  }

  private func clearUnacknowledgedRecoveryKeyInMemory(
    recoveryKey: String? = nil,
    productAccountId: String
  ) {
    guard unacknowledgedRecoveryAccountId == productAccountId,
      recoveryKey == nil || unacknowledgedRecoveryKey == recoveryKey
    else { return }
    unacknowledgedRecoveryKey = nil
    unacknowledgedRecoveryKeyMarker = nil
    unacknowledgedRecoveryAccountId = nil
  }

  func sharedMailboxFreshnessViewModel(
    for snapshot: ProductAccountSessionSnapshot,
    service: MailboxMetadataSyncing,
    successStore: MailboxSyncSuccessPersisting? = nil
  ) -> MailboxFreshnessViewModel {
    if let mailboxFreshnessSession,
      mailboxFreshnessSession.appleUserIdentifier == snapshot.appleUserIdentifier,
      mailboxFreshnessSession.productAccountId == snapshot.productAccountId,
      mailboxFreshnessSession.trustedDeviceId == snapshot.trustedDeviceId,
      let mailboxFreshnessViewModel
    {
      self.mailboxFreshnessSession = snapshot
      mailboxFreshnessViewModel.updateSession(snapshot)
      return mailboxFreshnessViewModel
    }

    clearMailboxFreshnessViewModel()
    let viewModel = MailboxFreshnessViewModel(
      service: service,
      session: snapshot,
      isSessionCurrent: { self.isCurrent($0) },
      isSessionIdentityCurrent: { self.isCurrentSessionIdentity($0) },
      successStore: successStore
    )
    mailboxFreshnessSession = snapshot
    mailboxFreshnessViewModel = viewModel
    return viewModel
  }

  func sharedMailActionViewModel(
    for snapshot: ProductAccountSessionSnapshot,
    service: MailboxProviderMailActing
  ) -> GmailMailActionViewModel {
    if let mailActionSession,
      mailActionSession.appleUserIdentifier == snapshot.appleUserIdentifier,
      mailActionSession.productAccountId == snapshot.productAccountId,
      mailActionSession.trustedDeviceId == snapshot.trustedDeviceId,
      let mailActionViewModel
    {
      self.mailActionSession = snapshot
      mailActionViewModel.updateSession(snapshot)
      return mailActionViewModel
    }

    clearMailActionViewModel()
    let viewModel = GmailMailActionViewModel(
      service: service,
      session: snapshot,
      revalidateTrustedDevice: {
        await self.revalidateTrustedDeviceAfterForegrounding()
      }
    )
    mailActionSession = snapshot
    mailActionViewModel = viewModel
    return viewModel
  }

  private func clearMailboxFreshnessViewModel(
    purgingPersistedStateFor productAccountId: String? = nil
  ) {
    if let productAccountId {
      mailboxFreshnessViewModel?.clearPersistedState()
      UserDefaultsMailboxSyncSuccessStore().clear(productAccountId: productAccountId)
    }
    mailboxFreshnessViewModel?.cancelAll()
    mailboxFreshnessSession = nil
    mailboxFreshnessViewModel = nil
  }

  private func clearMailActionViewModel() {
    let retiredViewModel = detachMailActionViewModel()
    guard let retiredViewModel else { return }
    retiredViewModel.beginPreparingForSignOut()
    Task { await retiredViewModel.prepareForSignOut() }
  }

  private func retireMailActionViewModelForSignOut() async {
    guard let retiredViewModel = detachMailActionViewModel() else { return }
    await retiredViewModel.prepareForSignOut()
  }

  private func detachMailActionViewModel() -> GmailMailActionViewModel? {
    let retiredViewModel = mailActionViewModel
    mailActionSession = nil
    mailActionViewModel = nil
    return retiredViewModel
  }
}
