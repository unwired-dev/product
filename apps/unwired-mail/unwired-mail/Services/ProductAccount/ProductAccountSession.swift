import Foundation
import Observation

// swiftlint:disable file_length

enum ProductAccountSessionState: Equatable {
  case loading
  case signedOut
  case signedIn(ProductAccountSessionSnapshot)
  case failed(String)
}

enum ProductAccountSessionError: LocalizedError, Equatable {
  case differentAppleAccount
  case recoveryNotBackedUp
  case recoveryNotPending

  var errorDescription: String? {
    switch self {
    case .differentAppleAccount:
      return "Recent authentication must use the current Product Account."
    case .recoveryNotBackedUp:
      return "Back up the Recovery Key before signing out on this device."
    case .recoveryNotPending:
      return "Sign in with Apple before restoring Product Sync with a Recovery Key."
    }
  }
}

@MainActor
@Observable
final class ProductAccountSession {
  private struct PendingProductSyncRecovery {
    let credential: AppleSignInCredential
    let recoveryMaterial: EncryptedProductSyncPayload
    let response: ProductAccountConnectResponse
  }

  private(set) var state: ProductAccountSessionState = .loading
  private(set) var requiresProductSyncRecovery = false

  @ObservationIgnored private var bootstrapTask: Task<Void, Never>?
  @ObservationIgnored private var mailboxFreshnessSession: ProductAccountSessionSnapshot?
  @ObservationIgnored private var mailboxFreshnessViewModel: MailboxFreshnessViewModel?
  @ObservationIgnored private var pendingProductSyncRecovery: PendingProductSyncRecovery?
  @ObservationIgnored private var signOutSnapshot: ProductAccountSessionSnapshot?
  private var isSigningOut = false
  private let appleSignInService: AppleSignInPerforming
  private let devicePushUnregistrationService: DevicePushUnregistering
  private let productAccountService: ProductAccountConnecting
  private let sessionStore: ProductAccountSessionPersisting
  private let mailboxConnectionService: MailboxConnectionClearing
  private let productSyncKeyMaterialStore: ProductSyncKeyMaterialPersisting

  init(
    appleSignInService: AppleSignInPerforming,
    devicePushUnregistrationService: DevicePushUnregistering =
      DevicePushUnregistrationService(),
    productAccountService: ProductAccountConnecting = ConvexProductAccountService(),
    sessionStore: ProductAccountSessionPersisting = KeychainProductAccountSessionStore(),
    mailboxConnectionService: MailboxConnectionClearing = ProductAccountMailboxConnectionClearer(),
    productSyncKeyMaterialStore: ProductSyncKeyMaterialPersisting =
      KeychainProductSyncKeyMaterialStore()
  ) {
    self.appleSignInService = appleSignInService
    self.devicePushUnregistrationService = devicePushUnregistrationService
    self.productAccountService = productAccountService
    self.sessionStore = sessionStore
    self.mailboxConnectionService = mailboxConnectionService
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

  func signInWithApple() async {
    state = .loading
    clearPendingProductSyncRecovery()

    do {
      try resumePendingSignOut()
      let credential = try await appleSignInService.signIn()
      let response = try await productAccountService.connect(
        identityToken: credential.identityToken
      )
      guard
        try await prepareProductSyncMaterial(
          credential: credential,
          response: response,
          allowCreation: shouldCreateProductSyncMaterialAfterSignIn(response: response)
        )
      else { return }
      try await completeSignIn(credential: credential, response: response)
    } catch {
      state = .failed(error.localizedDescription)
    }
  }

  func restoreProductSyncMaterial(recoveryKey rawValue: String) async {
    guard let pendingProductSyncRecovery else {
      state = .failed(ProductAccountSessionError.recoveryNotPending.localizedDescription)
      return
    }
    state = .loading

    do {
      _ = try productSyncKeyMaterialStore.restore(
        productAccountId: pendingProductSyncRecovery.response.productAccountId,
        recoveryKey: ProductSyncRecoveryKey(rawValue: rawValue),
        recoveryWrappedAccountKey:
          pendingProductSyncRecovery.recoveryMaterial.encryptedPayload
      )
      try await completeSignIn(
        credential: pendingProductSyncRecovery.credential,
        response: pendingProductSyncRecovery.response
      )
      clearPendingProductSyncRecovery()
    } catch {
      state = .failed(error.localizedDescription)
    }
  }

  func signOut(
    afterRecoveryCheck preparation: () async -> Void = {}
  ) async {
    beginSignOut()
    defer {
      isSigningOut = false
      signOutSnapshot = nil
    }
    let snapshot = signOutSnapshot ?? (try? sessionStore.load())
    do {
      try await prepareForSignOut(snapshot, preparation: preparation)
      if let snapshot {
        try? await devicePushUnregistrationService.unregister(session: snapshot)
        guard !signOutSnapshotWasReplaced(snapshot) else { return }
      }
      var mailboxCleanupError: Error?
      if let snapshot {
        do {
          try await mailboxConnectionService.clearLocalConnection(
            session: snapshot,
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
      if let snapshot {
        try? await unregisterTrustedDeviceForSignOut(snapshot)
        guard !signOutSnapshotWasReplaced(snapshot) else { return }
        try sessionStore.savePendingSignOutProductAccountId(
          snapshot.productAccountId
        )
        try resumePendingSignOut()
      } else {
        try sessionStore.clear()
      }
      guard
        currentSignedInSnapshot() == nil || currentSignedInSnapshot() == snapshot,
        (try? sessionStore.load()) == nil
      else { return }
      state = .signedOut
    } catch {
      state = .failed(error.localizedDescription)
    }
  }

  private func prepareForSignOut(
    _ snapshot: ProductAccountSessionSnapshot?,
    preparation: () async -> Void
  ) async throws {
    if let snapshot {
      try await verifyProductSyncRecoveryIsBackedUp(snapshot)
    }
    await preparation()
  }

  func isCurrent(_ snapshot: ProductAccountSessionSnapshot) -> Bool {
    !isSigningOut && currentSignedInSnapshot() == snapshot
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

  private func unregisterTrustedDeviceForSignOut(
    _ snapshot: ProductAccountSessionSnapshot
  ) async throws {
    _ = try await productAccountService.unregisterTrustedDevice(
      identityToken: snapshot.identityToken,
      trustedDeviceId: snapshot.trustedDeviceId
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
    try sessionStore.save(snapshot)
    do {
      try await clearLocalMailboxConnectionIfProductAccountChanged(
        from: existingSnapshot,
        to: snapshot
      )
    } catch {
      try? sessionStore.save(existingSnapshot)
      throw error
    }
    await unregisterDeviceIfProductAccountChanged(
      from: existingSnapshot,
      to: snapshot
    )
  }

  private func clearLocalMailboxConnectionIfProductAccountChanged(
    from existingSnapshot: ProductAccountSessionSnapshot?,
    to snapshot: ProductAccountSessionSnapshot
  ) async throws {
    guard
      let existingSnapshot,
      existingSnapshot.productAccountId != snapshot.productAccountId
    else {
      return
    }

    try await mailboxConnectionService.clearLocalConnection(session: existingSnapshot)
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
  private func verifyProductSyncRecoveryIsBackedUp(
    _ snapshot: ProductAccountSessionSnapshot
  ) async throws {
    let identityToken = try await identityTokenForRecoveryCheck(snapshot)
    guard
      try await productAccountService.productSyncRecoveryIsBackedUp(
        identityToken: identityToken
      )
    else {
      throw ProductAccountSessionError.recoveryNotBackedUp
    }
  }

  private func identityTokenForRecoveryCheck(
    _ snapshot: ProductAccountSessionSnapshot
  ) async throws -> String {
    guard snapshot.identityTokenState() != .active else {
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
        let recoveryMaterial = try await productAccountService.productSyncRecoveryMaterial(
          identityToken: credential.identityToken
        )
      else {
        throw ProductSyncKeyMaterialStoreError.recoveryRequired
      }
      pendingProductSyncRecovery = PendingProductSyncRecovery(
        credential: credential,
        recoveryMaterial: recoveryMaterial,
        response: response
      )
      requiresProductSyncRecovery = true
      state = .failed(ProductSyncKeyMaterialStoreError.recoveryRequired.localizedDescription)
      return false
    }
  }

  private func completeSignIn(
    credential: AppleSignInCredential,
    response: ProductAccountConnectResponse
  ) async throws {
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
    try sessionStore.save(snapshot)
    do {
      try await clearLocalMailboxConnectionIfProductAccountChanged(
        from: previousSnapshot,
        to: snapshot
      )
    } catch {
      if let previousSnapshot {
        try? sessionStore.save(previousSnapshot)
      }
      throw error
    }
    await unregisterDeviceIfProductAccountChanged(
      from: previousSnapshot,
      to: snapshot
    )
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
  private func performBootstrap() async {
    guard prepareForBootstrap() else { return }
    guard let snapshot = try? sessionStore.load() else {
      state = .signedOut
      return
    }

    do {
      let credential = try await appleSignInService.restoreSession(snapshot: snapshot)
      let response = try await productAccountService.connect(
        identityToken: credential.identityToken
      )
      guard
        try await prepareProductSyncMaterialForBootstrap(
          credential: credential,
          response: response
        )
      else { return }
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
      state = .signedIn(refreshedSnapshot)
    } catch let error as AppleSignInError {
      switch error {
      case .notAuthorized:
        try? await devicePushUnregistrationService.unregister(session: snapshot)
        do {
          try await clearRevokedSession(snapshot)
          state = .signedOut
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

  private func prepareForBootstrap() -> Bool {
    do {
      try resumePendingSignOut()
      return true
    } catch {
      state = .failed(error.localizedDescription)
      return false
    }
  }

  private func clearRevokedSession(
    _ snapshot: ProductAccountSessionSnapshot
  ) async throws {
    try await mailboxConnectionService.clearLocalConnection(session: snapshot)
    try sessionStore.savePendingSignOutProductAccountId(
      snapshot.productAccountId
    )
    try resumePendingSignOut()
  }

  private func resumePendingSignOut() throws {
    guard
      let productAccountId =
        try sessionStore.loadPendingSignOutProductAccountId()
    else {
      return
    }
    try sessionStore.clear()
    try productSyncKeyMaterialStore.clear(
      productAccountId: productAccountId
    )
    try sessionStore.clearPendingSignOutProductAccountId()
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
    signOutSnapshot = currentSignedInSnapshot()
    isSigningOut = true
    state = .loading
    clearMailboxFreshnessViewModel()
  }

  func sharedMailboxFreshnessViewModel(
    for snapshot: ProductAccountSessionSnapshot,
    service: MailboxMetadataSyncing
  ) -> MailboxFreshnessViewModel {
    if mailboxFreshnessSession == snapshot, let mailboxFreshnessViewModel {
      return mailboxFreshnessViewModel
    }

    clearMailboxFreshnessViewModel()
    let viewModel = MailboxFreshnessViewModel(
      service: service,
      session: snapshot,
      isSessionCurrent: { self.isCurrent($0) }
    )
    mailboxFreshnessSession = snapshot
    mailboxFreshnessViewModel = viewModel
    return viewModel
  }

  private func clearMailboxFreshnessViewModel() {
    mailboxFreshnessViewModel?.cancelAll()
    mailboxFreshnessSession = nil
    mailboxFreshnessViewModel = nil
  }
}
