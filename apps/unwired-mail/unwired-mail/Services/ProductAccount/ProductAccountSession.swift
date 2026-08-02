import Foundation
import Observation

// swiftlint:disable file_length

private let signOutTokenValidityMargin: TimeInterval = 5 * 60

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
  case recoveryNotBackedUp
  case recoveryKeyUnacknowledged
  case recoveryNotPending

  var errorDescription: String? {
    switch self {
    case .differentAppleAccount:
      return "Recent authentication must use the current Product Account."
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
  private(set) var signOutErrorMessage: String?
  private(set) var requiresProductSyncRecovery = false
  private(set) var unacknowledgedRecoveryKey: String?

  @ObservationIgnored private var bootstrapTask: Task<Void, Never>?
  @ObservationIgnored private var mailboxFreshnessSession: ProductAccountSessionSnapshot?
  @ObservationIgnored private var mailboxFreshnessViewModel: MailboxFreshnessViewModel?
  @ObservationIgnored private var pendingProductSyncRecovery: PendingProductSyncRecovery?
  @ObservationIgnored private var signOutTask: Task<Void, Never>?
  @ObservationIgnored private var signOutSnapshot: ProductAccountSessionSnapshot?
  @ObservationIgnored private var unacknowledgedRecoveryAccountId: String?
  @ObservationIgnored private var unacknowledgedRecoveryKeyMarker: UnacknowledgedRecoveryKey?
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

  func revalidateTrustedDeviceAfterForegrounding() async {
    guard let snapshot = currentSignedInSnapshot(), !isSigningOut else { return }
    await withProductAccountOperation(productAccountId: snapshot.productAccountId) {
      guard isCurrent(snapshot) else { return }
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
        guard isCurrent(snapshot) else { return }
        try sessionStore.save(refreshedSnapshot)
        state = .signedIn(refreshedSnapshot)
      } catch ProductAccountServiceError.trustedDeviceRevoked {
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
      } catch {
        // A transient foreground connectivity failure must not destroy an otherwise valid session.
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

  func signInWithApple() async {
    let coordinatedProductAccountId =
      currentSignedInSnapshot()?.productAccountId
      ?? (try? sessionStore.load())?.productAccountId
      ?? pendingProductSyncRecovery?.response.productAccountId
    await withProductAccountOperation(productAccountId: coordinatedProductAccountId) {
      state = .loading
      clearPendingProductSyncRecovery()

      do {
        try await resumePendingSignOut()
        let credential = try await appleSignInService.signIn()
        await resumePendingTrustedDeviceUnregistrations(using: credential)
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
      publishSignOutFailure(
        error,
        snapshot: snapshot,
        preparedDestructiveCleanup: preparedDestructiveCleanup
      )
    }
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
      } catch is CancellationError {
      } catch {
        state = .failed(error.localizedDescription)
      }
    }
  }

  private func withProductAccountOperation(
    productAccountId: String?,
    operation: () async -> Void
  ) async {
    if let productAccountId {
      await productAccountRecoveryOperationGate.acquire(
        productAccountId: productAccountId
      )
    }
    await operation()
    if let productAccountId {
      await productAccountRecoveryOperationGate.release(
        productAccountId: productAccountId
      )
    }
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

  private func publishSignOutFailure(
    _ error: Error,
    snapshot: ProductAccountSessionSnapshot?,
    preparedDestructiveCleanup: Bool
  ) {
    if !preparedDestructiveCleanup, let snapshot,
      !signOutSnapshotWasReplaced(snapshot)
    {
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
    let recoveryKeyMarker =
      try
      (unacknowledgedRecoveryAccountId == snapshot.productAccountId
      ? unacknowledgedRecoveryKeyMarker
      : nil)
      ?? sessionStore.loadUnacknowledgedRecoveryKey(
        productAccountId: snapshot.productAccountId
      )
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
    } catch let error as AppleSignInError {
      switch error {
      case .notAuthorized:
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
    var mailboxCleanupError: Error?
    do {
      try await mailboxConnectionService.clearLocalConnection(session: snapshot)
    } catch {
      mailboxCleanupError = error
    }
    if persistUnregistrationRetry {
      try persistTrustedDeviceUnregistrationRetry(snapshot)
    }
    try await resumePendingSignOut(resumingExternalCleanup: false)
    return mailboxCleanupError
  }

  private func resumePendingSignOut(
    resumingExternalCleanup: Bool = true
  ) async throws {
    guard
      let productAccountId =
        try sessionStore.loadPendingSignOutProductAccountId()
    else {
      return
    }
    if resumingExternalCleanup,
      let snapshot = try sessionStore.load(),
      snapshot.productAccountId == productAccountId
    {
      if snapshot.identityTokenState() == .active {
        try? await devicePushUnregistrationService.unregister(session: snapshot)
      } else {
        try persistTrustedDeviceUnregistrationRetry(snapshot)
      }
      try await mailboxConnectionService.clearLocalConnection(session: snapshot)
      if snapshot.identityTokenState() == .active {
        try await unregisterTrustedDeviceOrPersistForRetry(snapshot)
      }
    }
    try sessionStore.clear()
    try productSyncKeyMaterialStore.clear(
      productAccountId: productAccountId
    )
    try sessionStore.clearUnacknowledgedRecoveryKey(
      productAccountId: productAccountId
    )
    try sessionStore.clearPendingSignOutProductAccountId()
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
